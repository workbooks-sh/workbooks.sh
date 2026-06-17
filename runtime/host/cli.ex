defmodule Workbooks.CLI do
  @moduledoc """
  The `work` CLI — folded into the runtime mix project. One binary owns query,
  tangle, bundle, serve, and the variable store, calling straight into the same
  modules the Runtime uses. `call/2` returns output as a string (so an agent can
  run `work` in-process as a tool); `main/1` prints it.
  """
  alias Workbooks.{Workbook, Bundle, Vars, WorkKits}

  @version "0.1.0"

  def main(argv) do
    # Deploy + publish verbs are HOST-side (shell out + file config) — they need no
    # runtime, so they don't boot the app (which would load the wasmex NIF that
    # can't load from an escript archive). They carry exit codes + --json for agents.
    case argv do
      ["deploy" | rest] ->
        {out, failed?} = deploy_run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      ["publish" | rest] ->
        {out, failed?} = publish_run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work content check [dir]` validates a tenant CMS content tree (manifests
      # vs files, dup orders, faq-last, partial shape) — pure file reads, no app
      # boot. The agent's pre-publish gate so a broken page can't ship silently.
      ["content", "check"] -> content_check(".")
      ["content", "check", dir] -> content_check(dir)

      # `work rt …` drives a RUNNING runtime over HTTP (RCP client) — no app boot
      # (no NIF), just :httpc against the discovered/configured target.
      ["rt" | rest] ->
        {out, failed?} = Workbooks.CLI.Runtime.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work ctk …` — CTK human-in-the-loop helpers over the runtime HTTP (no app
      # boot). `work ctk await <run>` blocks until a review lands, then prints it.
      ["ctk" | rest] ->
        {out, failed?} = Workbooks.CLI.Runtime.ctk(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work toolkit …` stays a transparent alias for `work kit …` (the Rust thin
      # client still emits `toolkit` until its own rename; old muscle memory too).
      ["toolkit" | rest] -> main(["kit" | rest])

      # Release/version verbs are HOST-side & LOCAL (read workkits/releases.json +
      # .live.json from the repo) — no runtime needed, so handle before the RCP branch.
      ["kit", "versions", id] -> IO.puts(Workbooks.WorkKits.versions_text(id))
      ["kit", "live"] -> IO.puts(Workbooks.WorkKits.live_text())
      ["kit", "live", id] -> IO.puts(Workbooks.WorkKits.live_text(id, Workbooks.WorkKits.default_root()))
      ["kit", "rollback", id, version] -> IO.puts(Workbooks.WorkKits.rollback_text(id, version))

      # `work kit …` — toolkit surface over RCP (server-side; the escript can't
      # load the NIFs). HOST-side HTTP client → /rcp/toolkit/*. In-process callers
      # (an agent running work as a tool) still use `call/2` directly.
      ["kit" | rest] ->
        {out, failed?} = Workbooks.CLI.Runtime.toolkit(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work channels …` — messaging channels over RCP (list / send / approve
      # against the connected runtime's control plane; creds stay runtime-side).
      ["channels" | rest] ->
        {out, failed?} = Workbooks.CLI.Runtime.channels(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work dev …` — the development service: inspect the demo env + drive the
      # local verify loop (info / up / test). HOST-side, no app boot.
      ["dev" | rest] ->
        {out, failed?} = Workbooks.CLI.Dev.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work desktop …` installs/launches the GUI app — HOST-side (shells out to
      # the curl|sh installer), no app boot.
      ["desktop" | rest] ->
        {out, failed?} = Workbooks.CLI.Desktop.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `work demo seed …` — materialize the reproducible demo environment from the
      # git-backed Org fixture tree (recording-system findings §3). --dry-run
      # describes the plan with NO disk writes + NO app boot; a real run needs the
      # app (the build lane uses the wasmex NIF), so it boots first.
      ["demo" | rest] ->
        {out, failed?} = Workbooks.CLI.Demo.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      _ ->
        {:ok, _} = Application.ensure_all_started(:workbooks)
        IO.puts(call(argv))
    end
  end

  @doc "Run a work subcommand, returning its output. `tenant` scopes the variable store."
  def call(argv, tenant \\ "dev")

  def call(["content", "check"], tenant) do
    dir = if tenant in [nil, "dev"], do: ".", else: Workbooks.Git.repo_path(tenant)

    case Workbooks.Content.check(dir) do
      {:ok, summary} -> summary
      {:error, problems} -> "content check FAILED (#{length(problems)}):\n" <> Enum.map_join(problems, "\n", &("  - " <> &1))
    end
  end

  def call(["query", f], _t), do: with_workbook_file(f, &(&1 |> Workbook.parse_headlines() |> json()))
  def call(["tangle", f], _t), do: with_workbook_file(f, &(&1 |> Workbook.tangle_plan() |> json()))
  def call(["lint", f], _t), do: with_workbook_file(f, &(&1 |> Workbook.lint() |> json()))

  # Read a workbook HTML file for the parse/plan/lint verbs, confined to .html + no
  # traversal (wb-g1yo): the agent's `work query <path>` otherwise read ANY host file
  # (the CLI sibling of the HTTP read_workspace confinement). The only legit input
  # is an HTML workbook, so this blocks /etc/* + secrets while keeping the real use
  # intact.
  defp with_workbook_file(path, fun) do
    abs = Path.expand(to_string(path))

    cond do
      # An ABSOLUTE path could read any file on the host — including another
      # tenant's data under WB_DATA. query/tangle/lint operate on relative paths
      # only (the '..' guard then keeps them from climbing out).
      Path.type(to_string(path)) == :absolute -> ~s({"error":"only relative paths allowed"})
      String.contains?(to_string(path), "..") -> ~s({"error":"bad path"})
      Path.extname(abs) not in [".html", ".htm"] -> ~s({"error":"only workbook .html files can be read"})
      not File.regular?(abs) -> ~s({"error":"no such file"})
      true -> fun.(File.read!(abs))
    end
  end

  # The variable store + ref (per tenant).
  def call(["var", "set", key, value | rest], t) do
    secret? = "--secret" in rest
    Vars.set(t, key, value, secret?)
    "set #{key}" <> if(secret?, do: " (secret)", else: "")
  end

  def call(["var", "get", key], t) do
    case Vars.get(t, key) do
      {:ok, v} -> v
      {:secret, :redacted, n} -> "<secret: #{n} bytes — ref it with {{secret:#{key}}}, cannot read>"
      :error -> "no such var: #{key}"
    end
  end

  def call(["var", "list"], t) do
    case Vars.list(t) do
      m when map_size(m) == 0 -> "(no variables)"
      m -> Enum.map_join(m, "\n", fn {k, kind} -> "#{k}\t#{kind}" end)
    end
  end

  def call(["var", "ref" | rest], t), do: Vars.ref(t, Enum.join(rest, " "))

  # `work app …` — IN-PROCESS app control (wb-d2nx.1): an agent (Waldo) drives the
  # connected desktop shell by pushing `desktop:control` events the shell already
  # acts on. Distinct from the host-side `work desktop` installer verb in main/1.
  # No shell connected → reports "(no desktop shell connected)" rather than failing.
  def call(["app", "status"], _t) do
    case Workbooks.DesktopControl.listeners() do
      0 -> "(no desktop shell connected)"
      n -> "#{n} desktop shell#{if n == 1, do: "", else: "s"} connected"
    end
  end

  def call(["app", verb, path], t) when verb in ["open-tab", "close-tab", "focus-tab"] do
    action = verb |> String.replace_suffix("-tab", "")
    {:ok, n} = Workbooks.DesktopControl.tab(action, path, nil, t)
    if n == 0, do: "(no desktop shell connected — nothing to #{action})", else: "#{action} tab → #{path} (#{n} shell#{if n == 1, do: "", else: "s"})"
  end

  # App-control beyond tabs (wb-d2nx.2): theme / bookmark / workspace. Scoped to
  # the caller's tenant (wb-g1yo) so a command drives only their own shell.
  def call(["app", "theme", id], t),
    do: app_command("set_theme", %{"id" => id}, "theme → #{id}", t)

  def call(["app", "bookmark", path | rest], t) do
    title = if rest == [], do: path, else: Enum.join(rest, " ")
    app_command("bookmark", %{"path" => path, "title" => title}, "bookmarked #{path}", t)
  end

  def call(["app", "workspace", name | rest], t) do
    icon = List.first(rest) || ""
    app_command("new_workspace", %{"name" => name, "icon" => icon}, "workspace → #{name}", t)
  end

  def call(["app" | _], _t),
    do: "usage: work app <status | open-tab PATH | close-tab PATH | focus-tab PATH | theme ID | bookmark PATH [title] | workspace NAME [icon]>"

  defp app_command(action, args, ok_msg, tenant \\ nil) do
    case Workbooks.DesktopControl.command(action, args, tenant) do
      {:ok, 0} -> "(no desktop shell connected — nothing to do)"
      {:ok, n} -> "#{ok_msg} (#{n} shell#{if n == 1, do: "", else: "s"})"
    end
  end

  # `work env request NAME [reason…]` — ask the connected desktop to prompt the
  # user for a key/value (wb-kbq5.2). Blocks until they answer. On success the
  # value is stored in the runtime secret store (by reference) and the agent gets
  # a confirmation — never the raw value (secrets-by-reference).
  def call(["env", "request", name | rest], t) do
    reason = if rest == [], do: nil, else: Enum.join(rest, " ")

    case Workbooks.EnvBroker.request(name, reason, 120_000, t) do
      {:ok, value} ->
        Workbooks.Secrets.put(name, value)
        "provided — #{name} is now set (#{byte_size(value)} bytes), usable by reference"

      {:error, :no_desktop} -> "(no desktop shell connected to prompt — ask the user to add #{name} in Settings)"
      {:error, :timeout} -> "(timed out waiting for the user to provide #{name})"
      {:error, :cancelled} -> "(user declined to provide #{name})"
    end
  end

  def call(["env" | _], _t), do: "usage: work env request NAME [reason]"

  # `work models list [query]` — discover OpenRouter models (wb-d2nx.5). `work model
  # set ID` switches the model the agent runs on for the rest of the session.
  def call(["models", "list" | rest], _t), do: Workbooks.Models.list(Enum.join(rest, " "))
  def call(["models" | _], _t), do: "usage: work models list [query]"

  def call(["model", "set", id], t) do
    # PER-TENANT (wb-g1yo): store in the tenant's Vars, not a process-global env
    # var — on a shared nexus one tenant's model choice must not change everyone's.
    Workbooks.Vars.set(t, "wb.model", id)
    "model set to #{id}"
  end

  def call(["model", "get"], t) do
    # Effective model for THIS tenant: their Vars override, else the deploy-time
    # global default, else the built-in. Always a concrete id, never "(default)".
    case Workbooks.Vars.get(t, "wb.model") do
      {:ok, id} -> id
      _ -> System.get_env("WB_LLM_MODEL") || "#{Workbooks.Llm.default_model()} (default)"
    end
  end
  def call(["model" | _], _t), do: "usage: work model <get | set ID>"

  # `work workgate request CAP [reason…]` — ask the user to Allow/Deny an OS
  # capability (wb-kbq5.3). Blocks. Returns the decision.
  def call(["workgate", "request", cap | rest], t) do
    reason = if rest == [], do: nil, else: Enum.join(rest, " ")

    case Workbooks.WorkgateBroker.request(cap, reason, 120_000, t) do
      :allow -> "allowed: #{cap}"
      :deny -> "denied: #{cap}"
      {:error, :no_desktop} -> "(no desktop shell connected to prompt for #{cap})"
      {:error, :timeout} -> "(timed out waiting for an Allow/Deny on #{cap})"
    end
  end

  def call(["workgate" | _], _t), do: "usage: work workgate request CAPABILITY [reason]"

  # "Memory" is removed by design: the HTML/code files ARE the context. Recall =
  # `work search` (semantic) / `work library query` (literal); "remember" = write an
  # HTML workbook file. No separate store to drift. See docs/VECTOR-QUERY.md.

  # Single tree → one self-contained .html: pack the dir, embed the zip into the
  # page html. The page is the tree's own index/workbook .html.
  # (`work pack/unpack` is the workspace-level, multi-member sibling.)
  def call(["bundle", dir, out | flags], _t) do
    # The workbook compiler (docs/WORKBOOK-BUNDLE.md "lifecycle"): tangle the
    # <work-component> source out of the workbook HTML → native source, COMPILE
    # native → .wasm via the in-sandbox lanes (Workbooks.Build →
    # PackageManager/Compilers), then pack the tree INCLUDING the compiled .wasm so
    # the bundled .html carries the workbook HTML (re-editable), native (tangled),
    # and .wasm (runnable). `--no-build` packs source-only (the tangle still runs —
    # native source stays in sync with the workbook HTML).
    build? = "--no-build" not in flags

    parts =
      dir
      |> Bundle.read_tree()
      |> Bundle.tangle_files()
      |> Bundle.compile_tree(build: build?)

    blob = Bundle.pack(parts)
    html = parts["index.html"] || parts["workbook.html"] || ""

    # The page carries the wb-bundle zip (the filesystem). The STRUCTURE is the
    # work-* HTML itself — no separate manifest. A workbook IS HTML.
    page = Bundle.embed(html, blob)

    File.write!(out, page)
    "bundled #{map_size(parts)} files → #{out} (#{byte_size(blob)} bytes embedded)"
  end

  def call(["unbundle", in_html, dir], _t) do
    input = File.read!(in_html)
    # Accept BOTH forms: a self-contained `.html` (wb-bundle block) or a legacy raw
    # `.wbundle` zip — `read_any` dispatches. write_tree is path-confined (zip-slip
    # guard), and unpack carries the zip-bomb size/ratio guard.
    blob =
      cond do
        Bundle.embedded?(input) or String.starts_with?(input, "PK") -> Bundle.read_any(input)
        true -> raise "no wb-bundle in #{in_html}"
      end

    n = Bundle.write_tree(Bundle.unpack(blob), dir)
    "unbundled #{n} files → #{dir}"
  end

  # Dump a workbook's STRUCTURE — its `<work-*>` elements. A workbook IS HTML, so
  # this just reads the page (or a dir's index.html) with Floki — no manifest.
  def call(["structure", src], _t) do
    html =
      if File.dir?(src) do
        parts = Bundle.read_tree(src)
        parts["index.html"] || parts["workbook.html"] || ""
      else
        File.read!(src)
      end

    case Workbook.parse_headlines(html) do
      [] ->
        "no work-* elements in #{src}"

      rows ->
        listing = Enum.map_join(rows, "\n", fn r -> "  #{r["tagname"]}\t#{r["id"] || r["title"] || "-"}" end)
        "#{length(rows)} elements in #{src}:\n#{listing}"
    end
  end

  # Observability through the CLI (not a dashboard) — the telemetry + ledger
  # feedback loop over the always-on _steps.jsonl any run writes.
  def call(["telemetry"], t) do
    # Tenant-scoped (wb-g1yo): the CLI sibling of GET /api/telemetry — an agent's
    # `work telemetry` must only see its own tenant's runs, not every run on a nexus.
    runs = Workbooks.Workflow.Telemetry.index(t)
    if runs == [] do
      "(no runs)"
    else
      header = "SLUG\tSTAGE\tCALLS\tERRORS\tMS"
      rows = Enum.map_join(runs, "\n", fn r ->
        "#{r.slug}\t#{r.stage}\t#{r.tool_calls}\t#{r.errors}\t#{r.total_ms}"
      end)
      "#{header}\n#{rows}"
    end
  end

  def call(["telemetry", slug], t) do
    cond do
      String.contains?(slug, "/") or String.contains?(slug, "..") -> "bad slug"
      not Workbooks.Workflow.Telemetry.run_visible?(wd(slug), t) -> "no such run: #{slug}"
      true -> telemetry_summary_text(slug)
    end
  end

  defp telemetry_summary_text(slug) do
    case Workbooks.Workflow.Telemetry.summary(wd(slug)) do
      %{error: e} -> e
      s ->
        errs = Enum.map_join(s.errors, "\n", fn e -> "  ! step #{e.step} #{e.tool}: #{e.error}" end)
        "stage=#{s.stage} calls=#{s.tool_calls} errors=#{length(s.errors)} total_ms=#{s.total_ms}" <>
          if(s.errors == [], do: "", else: "\n" <> errs)
    end
  end

  def call(["ledger", slug], t) do
    cond do
      String.contains?(slug, "/") or String.contains?(slug, "..") -> "bad slug"
      not Workbooks.Workflow.Telemetry.run_visible?(wd(slug), t) -> "no such run: #{slug}"
      true -> ledger_verify_text(slug)
    end
  end

  defp ledger_verify_text(slug) do
    case Workbooks.Ledger.verify(wd(slug)) do
      %{error: e} -> e
      v ->
        mark = fn b -> if b, do: "ok", else: "FAIL" end
        "tamper-evident=#{mark.(v.tamper_evident)} attributable=#{mark.(v.attributable)} " <>
          "count=#{v.count} did=#{v.did}"
    end
  end

  # Sign a published artifact with the tenant's did:key (the sharing rail).
  def call(["sign", file | rest], t) do
    out = opt(rest, "--out") || file
    html = File.read!(file)
    signed = Workbooks.Manifest.sign(html, t, [%{"type" => "c2pa.action.published", "actor" => Workbooks.Git.did(t)}])
    File.write!(out, signed)
    "signed #{file} as #{Workbooks.Git.did(t)} → #{out}"
  end

  def call(["verify", file], _t) do
    case Workbooks.Manifest.verify(File.read!(file)) do
      %{error: e} -> e
      v -> "valid=#{v.valid} signature=#{v.signature} asset_integrity=#{v.asset_integrity} issuer=#{v.issuer_did}"
    end
  end

  # Library (Phase 3) — the identity's access graph + cross-workbook query.
  def call(["library"], t) do
    wss = Workbooks.Library.workspaces(t)
    if wss == [] do
      "(empty library)"
    else
      Enum.map_join(wss, "\n", fn ws ->
        members = Enum.map_join(ws.members, "\n", fn m ->
          {kind, ref} = m.ref
          "    #{m.id}\t#{kind}:#{ref}\t#{m.scope}"
        end)
        "#{ws.slug}  (#{length(ws.members)} members)\n#{members}"
      end)
    end
  end

  def call(["library", "query" | sql], t), do: Workbooks.Library.query(t, Enum.join(sql, " ")) |> json()

  def call(["checkout", member, workdir], t),
    do: Workbooks.Library.checkout(t, member, workdir) |> Map.drop([:member]) |> json()

  def call(["checkin", member, workdir], t),
    do: Workbooks.Library.checkin(t, member, workdir) |> Map.drop([:member]) |> json()

  # Compose a workspace's members into ONE parent workbook, and back.
  # `--build` → the RUNNABLE projection: compile components to WASM, drop source.
  def call(["pack", slug, out | rest], t) do
    case Workbooks.Library.pack(t, slug, build: "--build" in rest) do
      {:ok, blob} -> File.write!(out, blob); "packed #{slug} → #{out} (#{byte_size(blob)} bytes)"
      {:error, e} -> e
    end
  end

  # Compile a workspace's components → WASM; report what built / what couldn't.
  def call(["build", slug], t), do: Workbooks.Library.build(t, slug) |> json()

  # Source rail — mirror the tenant repo (the unpacked monorepo) to any git host.
  # A URL pushes anywhere; --forge auto-provisions via gh/glab/tea.
  def call(["mirror", url], t), do: Workbooks.Git.mirror(t, url) |> mirror_msg()

  def call(["mirror" | rest], t) do
    Workbooks.Git.forge_push(t,
      forge: opt(rest, "--forge"),
      repo: opt(rest, "--repo"),
      visibility: if("--public" in rest, do: "public", else: "private")
    ) |> mirror_msg()
  end

  # Radicle — federate the tenant repo over the P2P network (returns its rad: id).
  def call(["radicle"], t), do: (case Workbooks.Git.publish(t), do: (nil -> "radicle: not available"; rid -> "published → #{rid}"))

  def call(["unpack", bundle, dest], _t) do
    files = Workbooks.Library.unpack(File.read!(bundle), dest)
    "unpacked #{length(files)} files → #{dest}"
  end

  # Durable storage on the configured backend (local volume / S3 / R2).
  def call(["store", slug | rest], t) do
    case Workbooks.Library.store(t, slug, build: "--build" in rest) do
      {:ok, key} -> "stored #{slug} → #{key} (backend: #{Workbooks.Storage.adapter() |> Module.split() |> List.last()})"
      {:error, e} -> "error: #{e}"
    end
  end

  def call(["stored"], t) do
    case Workbooks.Library.stored(t) do
      [] -> "(nothing stored)"
      keys -> Enum.join(keys, "\n")
    end
  end

  def call(["fetch", key, out], t) do
    case Workbooks.Library.fetch(t, key) do
      {:ok, bytes} -> File.write!(out, bytes); "fetched #{key} → #{out} (#{byte_size(bytes)} bytes)"
      :error -> "not found: #{key}"
    end
  end

  # Query a workbook/library — semantic ∪ literal (hybrid). Consumer-agnostic;
  # any script/service uses the same surface an agent would. --semantic/--literal
  # force a single modality; --workbook <slug> scopes it.
  def call(["search" | rest], t) do
    {flags, words} = Enum.split_with(rest, &String.starts_with?(&1, "--"))
    mode = cond do "--semantic" in flags -> :semantic; "--literal" in flags -> :literal; true -> :hybrid end
    hits = Workbooks.Library.search(t, Enum.join(words, " "), mode: mode, workbook: opt(rest, "--workbook"), k: 8)

    if hits == [], do: "(no matches)",
      else: Enum.map_join(hits, "\n", fn h -> "#{h.workbook}/#{h.path} :: #{h.headline}\n  #{String.slice(h.text, 0, 80) |> String.replace("\n", " ")}" end)
  end

  # WorkKits (wb-4bj.2) — the agent's extensibility surface: discover toolkits and
  # read their progressive-disclosure skill recipes on demand (the CLI help-wrapper).
  def call(["toolkit" | rest], t), do: call(["kit" | rest], t)
  def call(["kit"], _t), do: WorkKits.list_text()
  def call(["kit", "list"], _t), do: WorkKits.list_text()
  def call(["kit", "show", id], _t), do: WorkKits.show_text(id)
  def call(["kit", "show", id, skill], _t), do: WorkKits.show_skill_text(id, skill)
  def call(["kit", "search" | q], _t), do: WorkKits.search_text(Enum.join(q, " "))
  def call(["kit", "verify", id], _t), do: WorkKits.verify_text(id)
  def call(["kit", "eval", id], _t), do: WorkKits.eval_text(id)
  # `work kit eval <id> <case>` — run ONE eval whose filename contains <case>.
  def call(["kit", "eval", id, filter], _t),
    do: WorkKits.eval_text(id, WorkKits.default_root(), filter)
  # `work eval components [case]` — the component-emit eval pack (text + voice parity).
  def call(["eval", "components"], _t), do: Workbooks.Evals.Components.run()
  def call(["eval", "components", filter], _t), do: Workbooks.Evals.Components.run(filter)
  def call(["kit", "sign", id], t), do: WorkKits.sign_text(id, t)
  def call(["kit", "versions", id], _t), do: WorkKits.versions_text(id)
  def call(["kit", "live"], _t), do: WorkKits.live_text()
  def call(["kit", "live", id], _t), do: WorkKits.live_text(id, WorkKits.default_root())
  def call(["kit", "rollback", id, version], _t), do: WorkKits.rollback_text(id, version)
  def call(["kit", "build", id], _t), do: WorkKits.build_text(id)
  def call(["kit", "build", id, which], _t), do: WorkKits.build_text(id, which, WorkKits.default_root())
  def call(["kit", "build-inline", name, lang, file], _t), do: WorkKits.build_inline_text(name, lang, file)
  def call(["kit", "promote", name, lang, file], _t), do: WorkKits.promote_text(name, lang, file)
  def call(["isolation"], _t), do: Workbooks.Isolation.describe()

  def call(["kit", "run", id, task | rest], _t),
    do: WorkKits.run_task_text(id, task, Enum.drop_while(rest, &(&1 == "--")))

  # Autopoet (wb-9ae / wb-pow) — the central self-improvement agent as an ON-DEMAND
  # surface. The backlog is bursty + small, so a triggered drain (any scheduler:
  # cron, a fly `machine exec`, CI) is the efficient shape — no always-on poller
  # idling on an empty backlog. `tick` runs ONE honesty-gated issue; `list`/`show`
  # read the backlog.
  def call(["autopoet"], _t), do: autopoet_list_text()
  def call(["autopoet", "list"], _t), do: autopoet_list_text()

  def call(["autopoet", "tick"], _t) do
    case Workbooks.Autopoet.Worker.drain_one() do
      {:worked, id, verdict} -> "autopoet: worked #{id} → #{verdict}"
      :empty -> "autopoet: backlog empty (no open :capability issue) — no run"
    end
  end

  def call(["autopoet", "show", id], _t) do
    case Workbooks.Autopoet.read_body(id) do
      {:ok, body} -> body
      _ -> "no such issue: #{id}"
    end
  end

  # Compiler-in-WASM (wb-zyl) — compilers run IN the sandbox (zero native execution).
  def call(["compiler"], _t), do: "compilers: " <> Enum.join(Workbooks.Compilers.list(), ", ")
  def call(["compiler", "list"], _t), do: "compilers: " <> Enum.join(Workbooks.Compilers.list(), ", ")

  def call(["compiler", "build", lang], _t) do
    case Workbooks.Compilers.build(lang) do
      {:ok, cli, wasm} -> "built #{lang} compiler → #{wasm}; registered command #{inspect(cli)}"
      {:error, reason} -> "compiler build FAILED for #{lang}: #{inspect(reason)}"
    end
  end

  def call(["compiler", "run", lang, file | argv], _t) do
    case Workbooks.Compilers.compile_run(lang, file, argv) do
      {:ok, out} -> out
      {:error, reason} -> "compile/run FAILED (#{lang} #{file}): #{inspect(reason)}"
    end
  end

  # Deploy-kit: ONE source of deploy logic — build/publish the runtime image, run
  # it locally (containerized) or cloud. Dogfooded: CI + the desktop app call these
  # same verbs. Routed through `deploy_run/1` (string interface; exit codes live in
  # main/1). Every verb is non-interactive, idempotent, and supports `--json`.
  def call(["deploy" | rest], _t), do: elem(deploy_run(rest), 0)

  def call(["version"], _t), do: "work #{@version} (engine plumbing — the user CLI is work)"
  def call(_, _t), do: usage()

  # Dispatch a deploy verb → {rendered_output, failed?}. `--json` anywhere in args
  # switches to machine-readable output.
  defp deploy_run(rest) do
    json? = Enum.member?(rest, "--json")
    args = Enum.reject(rest, &(&1 == "--json"))

    result =
      case args do
        [] -> {:ok, deploy_usage(), %{}}
        ["help" | _] -> {:ok, deploy_usage(), %{}}
        # The declarative model: scaffold → edit → validate → apply. The file
        # defaults to ./deployment.html, so most commands take no argument.
        ["init" | rest] -> Workbooks.Deploy.init(preset_arg(rest), force: "--force" in rest)
        # Scaffold CI that reconciles deployment.html on push (github|gitlab|generic).
        ["ci" | rest] -> Workbooks.Deploy.ci(ci_provider_arg(rest), force: "--force" in rest)
        ["validate" | rest] -> Workbooks.Deploy.validate(file_arg(rest))
        ["apply" | rest] -> Workbooks.Deploy.apply(file_arg(rest))
        # Quick zero-config local run (no file — like `docker run`).
        ["local" | _] -> Workbooks.Deploy.local()
        ["doctor"] -> Workbooks.Deploy.doctor()
        # ./deployment.html if present (local OR cloud), else the local daemon.
        ["status" | rest] -> Workbooks.Deploy.status(file_opt(rest))
        ["verify" | rest] -> Workbooks.Deploy.verify(file_opt(rest))
        ["down" | rest] -> Workbooks.Deploy.down(file_opt(rest))
        ["logs" | rest] -> Workbooks.Deploy.logs(file_opt(rest))
        # The one image artifact.
        ["build" | _] -> deploy_norm(Workbooks.Deploy.Image.build(into_krunvm: true))
        ["publish" | _] -> deploy_norm(Workbooks.Deploy.Image.publish())
        other -> {:error, "unknown verb: work deploy #{Enum.join(other, " ")}", %{}}
      end

    {Workbooks.Deploy.render(result, json?), Workbooks.Deploy.failed?(result)}
  end

  # Image.build/publish return {:ok|:error, string}; lift to the tagged contract.
  defp deploy_norm({:ok, msg}), do: {:ok, msg, %{}}
  defp deploy_norm({:error, msg}), do: {:error, msg, %{}}
  defp deploy_norm(:error), do: {:error, "command not found (is docker/buildx installed?)", %{}}

  # Dispatch a publish verb → {rendered_output, failed?}.
  defp publish_run(rest) do
    json? = Enum.member?(rest, "--json")
    args = Enum.reject(rest, &(&1 == "--json"))
    pub = Workbooks.Publish

    result =
      case args do
        [] -> {:ok, publish_usage(), %{}}
        ["help" | _] -> {:ok, publish_usage(), %{}}
        ["init" | rest] ->
          pub.init(force: "--force" in rest, file: pub_config_arg(rest))
        ["validate" | rest] ->
          pub.validate(pub_config_arg(rest))
        ["apply" | rest] ->
          workbook = pub_workbook_arg(rest)
          cfg = pub_config_arg(rest)
          pub.apply(workbook, cfg)
        ["site" | rest] ->
          dir = Enum.find(rest, ".", fn a -> not String.starts_with?(a, "-") end)
          site = Workbooks.Publish.Site
          case site.build(dir) do
            {:ok, msg, _data} -> {:ok, msg, %{}}
            {:error, msg} -> {:error, msg, %{}}
            {:error, msg, _data} -> {:error, msg, %{}}
          end
        other ->
          {:error, "unknown verb: work publish #{Enum.join(other, " ")}", %{}}
      end

    {pub.render_result(result, json?), pub.failed?(result)}
  end

  defp publish_usage do
    """
    work publish — render a Workbook (.html) → self-contained HTML → live URL.
    Non-interactive; add --json for machine output (exit 0 ok / non-zero fail).

    THE FLOW:
      work publish init                scaffold ./publish.html
      work publish validate            coherence-check it (no render, no deploy)
      work publish apply <file.html>   render + ship → prints the live URL
      work publish site [<dir>]        render multi-page site → deploy
    (config defaults to ./publish.html; workbook defaults to ./workbook.html)

    A publish.html is a <work-publish …> element whose attributes describe:
      publish-target   cloudflare-pages | gh-pages | self-hosted
      publish-project  the CF Pages project name, GitHub repo (org/name), or runtime URL
      publish-domain   optional custom domain (for the printed URL)
      publish-title    page <title> (falls back to publish-project)
      publish-output   where to write the rendered HTML (default: .publish_out/index.html)
    """
  end

  # The workbook arg is the HTML file to render; the config arg is the publish.html.
  # Both default via Workbooks.Publish; the only positional that names a workbook is
  # the one matching the workbook default's extension (.html).
  defp pub_workbook_arg(rest) do
    Enum.find(rest, Workbooks.Publish.default_workbook(), fn a ->
      not String.starts_with?(a, "-") and a != Workbooks.Publish.default_config() and
        String.ends_with?(a, ".html")
    end)
  end

  defp pub_config_arg(rest) do
    Enum.find(rest, Workbooks.Publish.default_config(), fn a ->
      not String.starts_with?(a, "-") and
        (a == Workbooks.Publish.default_config() or String.contains?(a, "publish"))
    end)
  end

  # File arg helpers — the deployment config defaults to ./deployment.html.
  defp preset_arg(rest), do: Enum.find(rest, "local", &(not String.starts_with?(&1, "-")))
  defp ci_provider_arg(rest), do: Enum.find(rest, "github", &(not String.starts_with?(&1, "-")))
  defp file_arg(rest), do: Enum.find(rest, "deployment.html", &(not String.starts_with?(&1, "-")))

  defp file_opt(rest) do
    case Enum.find(rest, &(not String.starts_with?(&1, "-"))) do
      nil -> if File.exists?("deployment.html"), do: "deployment.html", else: nil
      f -> f
    end
  end

  defp deploy_usage do
    """
    work deploy — stand up the Workbooks runtime, local or cloud. Non-interactive,
    idempotent; add --json to any verb for machine output (exit 0 ok / non-zero fail).

    THE FLOW (declarative — reproducible):
      work deploy init [local|cloud]   scaffold ./deployment.html
      work deploy ci [github|gitlab|generic]   scaffold CI that reconciles it on push
      work deploy validate             coherence-check it (no deploy)
      work deploy apply                deploy it — local microVM OR the cloud provider
      work deploy status|verify|logs   inspect / prove-live / tail   (reads ./deployment.html)
      work deploy down                 tear it down
    (commands default to ./deployment.html; pass a path to use another)

    QUICK (no config, like `docker run`):
      work deploy local                run the runtime locally right now
      work deploy doctor               check + self-heal local prerequisites

    A deployment.html is a <work-deploy …> element whose attributes describe:
      engine-place local|cloud · tenancy-mode single|multi · storage local-fs|s3
      database sqlite|postgres · auth trusted|clerk|… · profile · (cloud: provider, app)
    Secrets (S3 keys, DB DSN) come from your ENV, never the file.

    IMAGE:  work deploy build | publish   (build / push the one runtime image to ghcr)
    """
  end

  defp opt(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  defp mirror_msg({:ok, url}), do: "mirrored → #{url}"
  defp mirror_msg({:skip, r}), do: "skipped: #{r}"
  defp mirror_msg({:error, e}), do: "error: #{String.slice(to_string(e), 0, 300)}"

  defp wd(slug), do: "/tmp/bb/#{slug}"

  defp autopoet_list_text do
    case Workbooks.Autopoet.list() do
      [] ->
        "autopoet backlog: empty"

      issues ->
        Enum.map_join(issues, "\n", fn i ->
          "#{i.id}  [#{i.status}/#{i.kind}]  ×#{i.seen}  #{i.tenant}: #{i.title}"
        end)
    end
  end

  defp json(data), do: Jason.encode!(data, pretty: true)

  defp usage do
    """
    wb — Workbook CLI (#{@version})
      work query|tangle|lint <file.html>     workbook HTML → headlines / build plan / diagnostics
      work var set <key> <value> [--secret]  set a variable (secrets are ref-only)
      work var get <key>                     read a variable (secrets redacted)
      work var list                          list variables
      work var ref <template>                inject {{var:KEY}} / {{secret:KEY}}
      work bundle <dir> <out.html> [--no-build]  compile a dir tree → one self-contained .html
                                           (tangle org→native, compile native→wasm, then pack+embed;
                                            --no-build packs source-only, still tangling the org)
      work unbundle <in.html> <dir>          extract an embedded bundle → dir tree
      work telemetry [<slug>]                runs index, or one run's summary + errors
      work ledger <slug>                     verify a run's signed ledger (tamper/attribution)
      work sign <file.html> [--out <f>]      embed a did:key provenance manifest
      work verify <file.html>                check an artifact's signature + integrity
      work library                           list the tenant's workspaces + members
      work library query <sql>               cross-workbook query across members' VFS
      work checkout <member> <workdir>       borrow a member into a working dir
      work checkin <member> <workdir>        pack + sign a member back into the library
      work pack <workspace> <out> [--build]  compose members → one workbook (--build = compile to WASM)
      work build <workspace>                 compile components → WASM; report built/unbuilt
      work mirror <remote-url>               mirror the tenant repo to any git host (push)
      work mirror [--forge github|gitlab|gitea] [--repo n] [--public]   auto-provision + push
      work radicle                           federate the tenant repo over Radicle (P2P)
      work unpack <bundle> <dest>            disassemble a parent workbook → flat tree
      work kit [list]                    list discoverable toolkits (id · status · tagline)
      work kit show <id> [<skill>]       manifest + skill index, or one skill (with CAPTION TOC)
      work kit search <query>            substring search across all skills
      work kit verify <id>               structural checks + #+EXEC satisfiable + run :role pre blocks
      work kit versions <id>             list available versions/tags (releases.json ∪ manifest VERSION)
      work kit live [<id>]               show the currently-live version (all toolkits, or one)
      work kit rollback <id> <version>   pin the live version back to an older release
      work kit build <id>                declarative auto-wrap: build #+BUILD_SRC → register the command
      work kit build-inline <name> <lang> <file>  self-author: build a source file → register a command (rust/c/zig/js/ts/go)
      work kit promote <name> <lang> <file>       promote a session command → durable workspace toolkit (source-owned, packable)
      work isolation                                  show the isolation-tier ladder (the (width,tier) depth knob)
      work kit run <id> <task> -- <args> run a skill's :role task block with positional args
      work publish init                          scaffold ./publish.html
      work publish validate                      coherence-check it
      work publish apply <file.html>             render + deploy → live URL
      work desktop install [--version=X]         install the desktop app (curl | sh)
      work desktop open                          launch the installed desktop app
      work version
    """
  end

  defp content_check(dir) do
    case Workbooks.Content.check(dir) do
      {:ok, summary} ->
        IO.puts(summary)

      {:error, problems} ->
        IO.puts("content check FAILED (#{length(problems)}):")
        Enum.each(problems, &IO.puts("  - #{&1}"))
        System.halt(1)
    end
  end

end
