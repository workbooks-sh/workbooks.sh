defmodule Workbooks.CLI do
  @moduledoc """
  The `wb` CLI — folded into the runtime mix project. One binary owns query,
  tangle, bundle, serve, and the variable store, calling straight into the same
  modules the Runtime uses. `call/2` returns output as a string (so an agent can
  run `wb` in-process as a tool); `main/1` prints it.
  """
  alias Workbooks.{OQL, Bundle, Vars, Toolkits}

  @version "0.1.0"

  def main(argv) do
    # Deploy + publish verbs are HOST-side (shell out + file config) — they need no
    # runtime, so they don't boot the app (which would load the OQL/wasmex NIF that
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

      # `wb rt …` drives a RUNNING runtime over HTTP (RCP client) — no app boot
      # (no NIF), just :httpc against the discovered/configured target.
      ["rt" | rest] ->
        {out, failed?} = Workbooks.CLI.Runtime.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `wb ctk …` — CTK human-in-the-loop helpers over the runtime HTTP (no app
      # boot). `wb ctk await <run>` blocks until a review lands, then prints it.
      ["ctk" | rest] ->
        {out, failed?} = Workbooks.CLI.Runtime.ctk(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `wb dev …` — the development service: inspect the demo env + drive the
      # local verify loop (info / up / test). HOST-side, no app boot.
      ["dev" | rest] ->
        {out, failed?} = Workbooks.CLI.Dev.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      # `wb desktop …` installs/launches the GUI app — HOST-side (shells out to
      # the curl|sh installer), no app boot.
      ["desktop" | rest] ->
        {out, failed?} = Workbooks.CLI.Desktop.run(rest)
        IO.puts(out)
        if failed?, do: System.halt(1)

      _ ->
        {:ok, _} = Application.ensure_all_started(:workbooks)
        IO.puts(call(argv))
    end
  end

  @doc "Run a wb subcommand, returning its output. `tenant` scopes the variable store."
  def call(argv, tenant \\ "dev")

  def call(["query", f], _t), do: f |> File.read!() |> OQL.parse_headlines() |> json()
  def call(["tangle", f], _t), do: f |> File.read!() |> OQL.tangle_plan() |> json()
  def call(["lint", f], _t), do: f |> File.read!() |> OQL.lint() |> json()

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

  # "Memory" is removed by design: the org/code files ARE the context. Recall =
  # `wb search` (semantic) / `wb library query` (literal); "remember" = write an
  # org file. No separate store to drift. See docs/VECTOR-QUERY.org.

  def call(["bundle", src, dest], _t) do
    org = File.read!(src)
    parts = %{"source.org" => org, "manifest.json" => Jason.encode!(%{components: OQL.tangle_plan(org), v: 1})}
    File.write!(dest, Bundle.pack(parts))
    "bundled #{map_size(parts)} parts → #{dest}"
  end

  # Observability through the CLI (not a dashboard) — the telemetry + ledger
  # feedback loop over the always-on _steps.jsonl any run writes.
  def call(["telemetry"], _t) do
    runs = Workbooks.Workflow.Telemetry.index()
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

  def call(["telemetry", slug], _t) do
    case Workbooks.Workflow.Telemetry.summary(wd(slug)) do
      %{error: e} -> e
      s ->
        errs = Enum.map_join(s.errors, "\n", fn e -> "  ! step #{e.step} #{e.tool}: #{e.error}" end)
        "stage=#{s.stage} calls=#{s.tool_calls} errors=#{length(s.errors)} total_ms=#{s.total_ms}" <>
          if(s.errors == [], do: "", else: "\n" <> errs)
    end
  end

  def call(["ledger", slug], _t) do
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

  # Toolkits (wb-4bj.2) — the agent's extensibility surface: discover toolkits and
  # read their progressive-disclosure skill recipes on demand (the CLI help-wrapper).
  def call(["toolkit"], _t), do: Toolkits.list_text()
  def call(["toolkit", "list"], _t), do: Toolkits.list_text()
  def call(["toolkit", "show", id], _t), do: Toolkits.show_text(id)
  def call(["toolkit", "show", id, skill], _t), do: Toolkits.show_skill_text(id, skill)
  def call(["toolkit", "search" | q], _t), do: Toolkits.search_text(Enum.join(q, " "))
  def call(["toolkit", "verify", id], _t), do: Toolkits.verify_text(id)
  def call(["toolkit", "eval", id], _t), do: Toolkits.eval_text(id)
  def call(["toolkit", "sign", id], t), do: Toolkits.sign_text(id, t)
  def call(["toolkit", "build", id], _t), do: Toolkits.build_text(id)
  def call(["toolkit", "build", id, which], _t), do: Toolkits.build_text(id, which, Toolkits.default_root())
  def call(["toolkit", "build-inline", name, lang, file], _t), do: Toolkits.build_inline_text(name, lang, file)
  def call(["toolkit", "promote", name, lang, file], _t), do: Toolkits.promote_text(name, lang, file)
  def call(["isolation"], _t), do: Workbooks.Isolation.describe()

  def call(["toolkit", "run", id, task | rest], _t),
    do: Toolkits.run_task_text(id, task, Enum.drop_while(rest, &(&1 == "--")))

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

  def call(["version"], _t), do: "wb #{@version}"
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
        # defaults to ./deployment.org, so most commands take no argument.
        ["init" | rest] -> Workbooks.Deploy.init(preset_arg(rest), force: "--force" in rest)
        ["validate" | rest] -> Workbooks.Deploy.validate(file_arg(rest))
        ["apply" | rest] -> Workbooks.Deploy.apply(file_arg(rest))
        # Quick zero-config local run (no file — like `docker run`).
        ["local" | _] -> Workbooks.Deploy.local()
        ["doctor"] -> Workbooks.Deploy.doctor()
        # ./deployment.org if present (local OR cloud), else the local daemon.
        ["status" | rest] -> Workbooks.Deploy.status(file_opt(rest))
        ["verify" | rest] -> Workbooks.Deploy.verify(file_opt(rest))
        ["down" | rest] -> Workbooks.Deploy.down(file_opt(rest))
        ["logs" | rest] -> Workbooks.Deploy.logs(file_opt(rest))
        # The one image artifact.
        ["build" | _] -> deploy_norm(Workbooks.Deploy.Image.build(into_krunvm: true))
        ["publish" | _] -> deploy_norm(Workbooks.Deploy.Image.publish())
        other -> {:error, "unknown verb: wb deploy #{Enum.join(other, " ")}", %{}}
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
          org = pub_org_arg(rest)
          cfg = pub_config_arg(rest)
          pub.apply(org, cfg)
        ["site" | rest] ->
          dir = Enum.find(rest, ".", fn a -> not String.starts_with?(a, "-") end)
          site = Workbooks.Publish.Site
          case site.build(dir) do
            {:ok, msg, _data} -> {:ok, msg, %{}}
            {:error, msg} -> {:error, msg, %{}}
            {:error, msg, _data} -> {:error, msg, %{}}
          end
        other ->
          {:error, "unknown verb: wb publish #{Enum.join(other, " ")}", %{}}
      end

    {pub.render_result(result, json?), pub.failed?(result)}
  end

  defp publish_usage do
    """
    wb publish — render a Workbook (.org) → self-contained HTML → live URL.
    Non-interactive; add --json for machine output (exit 0 ok / non-zero fail).

    THE FLOW:
      wb publish init                scaffold ./publish.org
      wb publish validate            coherence-check it (no render, no deploy)
      wb publish apply <file.org>    render + ship → prints the live URL
      wb publish site [<dir>]        render multi-page site from site.org → deploy
    (config defaults to ./publish.org; workbook defaults to ./workbook.org)

    A publish.org describes:
      PUBLISH_TARGET  cloudflare-pages | gh-pages | self-hosted
      PUBLISH_PROJECT the CF Pages project name, GitHub repo (org/name), or runtime URL
      PUBLISH_DOMAIN  optional custom domain (for the printed URL)
      PUBLISH_TITLE   page <title> (falls back to PUBLISH_PROJECT)
      PUBLISH_OUTPUT  where to write the rendered HTML (default: .publish_out/index.html)
    """
  end

  defp pub_org_arg(rest) do
    Enum.find(rest, Workbooks.Publish.default_workbook(), fn a ->
      not String.starts_with?(a, "-") and String.ends_with?(a, ".org")
    end)
  end

  defp pub_config_arg(rest) do
    Enum.find(rest, Workbooks.Publish.default_config(), fn a ->
      not String.starts_with?(a, "-") and not String.ends_with?(a, ".org")
    end)
  end

  # File arg helpers — the deployment.org defaults to ./deployment.org.
  defp preset_arg(rest), do: Enum.find(rest, "local", &(not String.starts_with?(&1, "-")))
  defp file_arg(rest), do: Enum.find(rest, "deployment.org", &(not String.starts_with?(&1, "-")))

  defp file_opt(rest) do
    case Enum.find(rest, &(not String.starts_with?(&1, "-"))) do
      nil -> if File.exists?("deployment.org"), do: "deployment.org", else: nil
      f -> f
    end
  end

  defp deploy_usage do
    """
    wb deploy — stand up the Workbooks runtime, local or cloud. Non-interactive,
    idempotent; add --json to any verb for machine output (exit 0 ok / non-zero fail).

    THE FLOW (declarative — reproducible):
      wb deploy init [local|cloud]   scaffold ./deployment.org
      wb deploy validate             coherence-check it (no deploy)
      wb deploy apply                deploy it — local microVM OR the cloud provider
      wb deploy status|verify|logs   inspect / prove-live / tail   (reads ./deployment.org)
      wb deploy down                 tear it down
    (commands default to ./deployment.org; pass a path to use another)

    QUICK (no config, like `docker run`):
      wb deploy local                run the runtime locally right now
      wb deploy doctor               check + self-heal local prerequisites

    A deployment.org describes:
      ENGINE_PLACE local|cloud · TENANCY_MODE single|multi · STORAGE local-fs|s3
      DATABASE sqlite|postgres · AUTH trusted|clerk|… · PROFILE · (cloud: PROVIDER, APP)
    Secrets (S3 keys, DB DSN) come from your ENV, never the file.

    IMAGE:  wb deploy build | publish   (build / push the one runtime image to ghcr)
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

  defp json(data), do: Jason.encode!(data, pretty: true)

  defp usage do
    """
    wb — Workbook CLI (#{@version})
      wb query|tangle|lint <file.org>      Org → headlines / build plan / diagnostics
      wb var set <key> <value> [--secret]  set a variable (secrets are ref-only)
      wb var get <key>                     read a variable (secrets redacted)
      wb var list                          list variables
      wb var ref <template>                inject {{var:KEY}} / {{secret:KEY}}
      wb bundle <src.org> <out>            pack a Workbook Bundle
      wb telemetry [<slug>]                runs index, or one run's summary + errors
      wb ledger <slug>                     verify a run's signed ledger (tamper/attribution)
      wb sign <file.html> [--out <f>]      embed a did:key provenance manifest
      wb verify <file.html>                check an artifact's signature + integrity
      wb library                           list the tenant's workspaces + members
      wb library query <sql>               cross-workbook query across members' VFS
      wb checkout <member> <workdir>       borrow a member into a working dir
      wb checkin <member> <workdir>        pack + sign a member back into the library
      wb pack <workspace> <out> [--build]  compose members → one workbook (--build = compile to WASM)
      wb build <workspace>                 compile components → WASM; report built/unbuilt
      wb mirror <remote-url>               mirror the tenant repo to any git host (push)
      wb mirror [--forge github|gitlab|gitea] [--repo n] [--public]   auto-provision + push
      wb radicle                           federate the tenant repo over Radicle (P2P)
      wb unpack <bundle> <dest>            disassemble a parent workbook → flat tree
      wb toolkit [list]                    list discoverable toolkits (id · status · tagline)
      wb toolkit show <id> [<skill>]       manifest + skill index, or one skill (with CAPTION TOC)
      wb toolkit search <query>            substring search across all skills
      wb toolkit verify <id>               structural checks + #+EXEC satisfiable + run :role pre blocks
      wb toolkit build <id>                declarative auto-wrap: build #+BUILD_SRC → register the command
      wb toolkit build-inline <name> <lang> <file>  self-author: build a source file → register a command (rust/c/zig/js/ts/go)
      wb toolkit promote <name> <lang> <file>       promote a session command → durable workspace toolkit (source-owned, packable)
      wb isolation                                  show the isolation-tier ladder (the (width,tier) depth knob)
      wb toolkit run <id> <task> -- <args> run a skill's :role task block with positional args
      wb publish init                          scaffold ./publish.org
      wb publish validate                      coherence-check it
      wb publish apply <file.org>              render + deploy → live URL
      wb desktop install [--version=X]         install the desktop app (curl | sh)
      wb desktop open                          launch the installed desktop app
      wb version
    """
  end
end
