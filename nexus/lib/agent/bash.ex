defmodule Nexus.Agent.Bash do
  @moduledoc """
  `bash` — the agent's ONE tool. The agent does everything by running a command line here. A shell
  command runs on **Washy** (`Nexus.Shell` / `Nexus.Washy`) — our featured shell (grammar: for/if/
  while/vars) compiled to wasm and run IN-PROCESS on the pure-Elixir interpreter (BEAM-isolated,
  bounded), with the full coreutils tool set provided by `host_exec` (the thesis's fork/exec
  emulation). Dense — no wasmer subprocess. HOST CAPABILITIES — `agent` (delegate), `request`
  (autopoiesis), `work` (the in-process .work CLI), `image|video|speak` (generate), and the web
  commands — are dispatched in Elixir (the BEAM owns orchestration; they also compose mid-pipe via a
  host_exec hook). The `/work` mount is the trust boundary.
  """

  # The host-brokered web commands (not wasm kits) — gated by a `web`/`net`/`browse` grant.
  @web_cmds ~w(fetch scrape render screenshot search navigate links forms click fill submit)

  # Host-brokered GENERATOR commands (not wasm kits) — text → image/video/audio via a gateway model
  # (`Nexus.Generator`). Each is gated on the matching generator toolkit being an ACTIVE capability for
  # the run (the composer's capability selection), so generation only happens when the user enabled it.
  @gen_cmds ~w(image video speak)
  @gen_modality %{"image" => "image", "video" => "video", "speak" => "audio"}
  @gen_toolkit %{"image" => "image-generation", "video" => "video-generation", "speak" => "speech"}

  @doc "Run a command line against `vfs` (unrestricted). Returns combined stdout."
  def run(vfs, line) when is_binary(line), do: run(vfs, line, nil)

  @doc """
  Run the agent's command line. HOST CAPABILITIES (`agent`/`request`/`work`/`image|video|speak`/web)
  run in Elixir — the BEAM owns orchestration. EVERYTHING ELSE runs on the Washy shell over the agent's
  `/work` (grammar + coreutils via host_exec), in-process + BEAM-isolated + bounded. `perms`
  (`%{grant: […]}`) gates web + scopes the run; a `:session` pid routes to a stateful Washy session.
  """
  def run(vfs, line, perms) when is_binary(line) do
    case tokenize(line) do
      [] ->
        ""

      [cmd | args] ->
        case host_dispatch(vfs, cmd, args, "", perms) do
          {:host, out} ->
            out

          :not_host ->
            shell(line, vfs, perms)
        end
    end
  end

  # A shell command runs either in a LONG-LIVED session (Phase 6 — `perms[:session]` carries a
  # `Nexus.Wasmer.Session` pid, so cwd/env persist across the agent's commands) or, by default, as a
  # fresh one-shot wasmer subprocess. Host caps never reach here (they resolved on the Membrane above).
  defp shell(line, _vfs, %{session: session} = _perms) when is_pid(session) do
    {out, _code} = Nexus.Washy.Session.run(session, line)
    out
  end

  defp shell(line, vfs, perms) do
    # let host capabilities (work/agent/request/web) compose MID-PIPE: the washy shell's host_exec
    # calls this back when a pipeline stage is a host cap, routing it through the Membrane (Elixir).
    Process.put(:washy_host_dispatch, fn [cmd | args], stdin ->
      if host_command?(cmd) do
        case host_dispatch(vfs, cmd, args, stdin, perms) do
          {:host, out} -> {out, 0}
          _ -> :not_host
        end
      else
        :not_host
      end
    end)

    # If a CLI-backed connection is active for this run (a consumer toolkit in `caps`), inject its
    # credentials as env and enforce its scope as an exec policy — so `gws …` runs authenticated and a
    # blocked command group fails closed. `[]` when no such connection: a plain shell run.
    tenant = is_map(perms) && perms[:tenant]
    caps = (is_map(perms) && perms[:caps]) || []
    conn = if is_binary(tenant), do: Nexus.CliConnections.run_opts(tenant, caps), else: []

    dir = Nexus.Agent.Vfs.dir(vfs)
    written = write_conn_files(dir, Keyword.get(conn, :files, []))

    # A sandboxed CLI (e.g. gws) has no sockets — its in-process HTTP rides host_http through to the
    # host's SSRF-guarded transport. Wire it ONLY when the run holds a web/net grant; ungranted runs get
    # no transport (host_http returns -1), so a guest can't reach the network without permission.
    run_opts = Keyword.take(conn, [:env, :exec_policy])

    run_opts =
      if web_granted?(is_map(perms) && Map.get(perms, :grant, [])) do
        # HTTP (Layer 1) + raw TCP (Layer 2) — both host-brokered, both behind the web/net grant.
        run_opts
        |> Keyword.put(:http, &Nexus.Dock.serve/1)
        |> Keyword.put(:sock, Nexus.Dock.tcp_handler())
      else
        run_opts
      end

    out =
      try do
        {o, _ok} = Nexus.Shell.run(line, dir, run_opts)
        o
      after
        # Credential files are transient — never persist a plaintext secret in the tenant's /work.
        Enum.each(written, &File.rm/1)
        Process.delete(:washy_host_dispatch)
      end

    out
  end

  # Write a connection's credential files into the run's /work just-in-time (a per-connection path).
  # Returns the absolute paths written, so the caller can delete them after the run.
  defp write_conn_files(dir, files) do
    Enum.flat_map(files, fn %{path: path, content: content} ->
      rel = String.trim_leading(path, "/work/")
      abs = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
      [abs]
    end)
  end

  # ── The Membrane seam (wb-g5w3) ─────────────────────────────────────────────────────────────────
  # ONE place every HOST capability (work/agent/request/web/generate) resolves — regardless of which
  # transport delivered it. Today there is one transport: the agent's first-word path above. The
  # WASIX-socket bridge (the in-sandbox `exec`, so `cat x | work parse` composes in a real bash pipe)
  # is the SECOND transport, and it calls THIS same function — so a host cap behaves identically whether
  # bash intercepts it as word #1 or execs it mid-pipe. That sameness is what makes the two engines feel
  # like one system. `stdin` is the piped input ("" for the first-word path).
  @host_caps ["agent", "request", "work"]

  @doc "Whether `cmd` is a HOST capability (resolves in Elixir via the Membrane, not the wasm shell)."
  def host_command?(cmd), do: cmd in @host_caps or cmd in @gen_cmds or cmd in @web_cmds

  @doc """
  Dispatch one host capability through the Membrane. Returns `{:host, output}` when `cmd` is a host
  capability, else `:not_host` (a real program the wasm shell should run). The single bus both transports
  share.
  """
  def host_dispatch(vfs, cmd, args, stdin, perms) do
    cond do
      cmd == "agent" -> {:host, run_subagent(args, stdin, perms)}
      cmd == "request" -> {:host, run_request(args, stdin)}
      cmd == "work" -> {:host, run_work(vfs, args, perms)}
      cmd in @gen_cmds -> {:host, run_generate(cmd, args, stdin, perms)}
      cmd in @web_cmds ->
        case permit(cmd, perms) do
          :ok -> {:host, dispatch(vfs, cmd, args, stdin)}
          {:deny, msg} -> {:host, msg}
        end

      true ->
        :not_host
    end
  end

  # Minimal quote-aware tokenizer — ONLY to detect a host-capability first word + its args. The shell
  # path hands the RAW line to bash (it does its own full parsing), so we never re-implement a shell.
  defp tokenize(line) do
    Regex.scan(~r/'[^']*'|"[^"]*"|\S+/, line)
    |> Enum.map(fn [t] -> t |> String.trim("\"") |> String.trim("'") end)
  end

  @max_depth 3

  defp run_subagent([], _stdin, _perms), do: "agent: usage: agent <name> <task>  (or pipe the task via stdin)"

  defp run_subagent([name | task_args], stdin, perms) do
    depth = (is_map(perms) && perms[:depth]) || 0
    task = case Enum.join(task_args, " ") |> String.trim() do
             "" -> String.trim(stdin || "")
             t -> t
           end

    cond do
      depth >= @max_depth ->
        "agent: max sub-agent depth (#{@max_depth}) reached — cannot delegate further"

      task == "" ->
        "agent: no task given (pass as args or pipe via stdin)"

      true ->
        # Forward the sub-agent's LIVE events (tokens/tools/final, already self-tagged with its name +
        # depth) onto the parent's stream, bracketed by agent_start/agent_end — so a UI shows nested,
        # real-time progress of every delegated agent (incl. parallel fan-out).
        ps = is_map(perms) && perms[:stream]
        opts = sub_opts(name, task, depth, perms)
        {opts, notify} =
          if is_function(ps, 1) do
            ps.(%{type: "agent_start", agent: name, task: task, depth: depth + 1})
            {Keyword.put(opts, :emit, ps), fn ok -> ps.(%{type: "agent_end", agent: name, depth: depth + 1, ok: ok}) end}
          else
            {opts, fn _ -> :ok end}
          end

        result = Nexus.Agent.run_named(name, task, opts)
        notify.(match?({:ok, _}, result))

        case result do
          {:ok, %{answer: a}} when is_binary(a) -> a
          {:error, {:no_agent, n}} -> "agent: no such agent: #{n}"
          {:error, e} -> "agent: sub-agent run failed: #{inspect(e)}"
          _ -> "agent: (no answer)"
        end
    end
  end

  # Sub-agent run options. Depth + grant-ceiling always apply. When the PARENT is running in a shared
  # workspace, the sub-agent inherits it — but on its OWN unique branch — so it edits real files in its own
  # jj worktree and FIFO-integrates into main (concurrency-safe via Nexus.JJ.with_repo_lock). This is what
  # turns delegation into ORCHESTRATION: workhorse fans subtasks out to agents that build the shared tree,
  # not just return text. Without a parent workspace, the sub-agent stays text-only (ephemeral VFS).
  @doc false
  # Test seam — the sub-agent option derivation (workspace inheritance + unique branch).
  def sub_opts_for_test(name, task, depth, perms), do: sub_opts(name, task, depth, perms)

  defp sub_opts(name, task, depth, perms) do
    base = [depth: depth + 1, grant_ceiling: is_map(perms) && perms[:grant]]

    case is_map(perms) && perms[:workspace] do
      %{} = ws ->
        branch = "agent/#{name}-#{System.unique_integer([:positive])}"
        message = "#{name}: #{String.slice(task, 0, 80)}"
        Keyword.put(base, :workspace, Map.merge(ws, %{name: name, branch: branch, author: "#{name} <#{name}>", message: message}))

      _ ->
        base
    end
  end

  defp run_request([], _stdin), do: "request: usage: request <self|agent> <typed change>  (e.g. request self 'grant +net')"

  defp run_request([target | change_args], stdin) do
    change =
      case Enum.join(change_args, " ") |> String.trim() do
        "" -> String.trim(stdin || "")
        c -> c
      end

    why = if change_args != [] and is_binary(stdin), do: String.trim(stdin), else: nil

    case Nexus.Autopoet.Request.new(%{target: target, change: change, why: why}) do
      {:ok, req} ->
        Nexus.Autopoet.Request.file(req)
        "request: filed (#{req.target}: #{req.change}) — continue working, the autopoet handles it async (no need to wait)"

      {:error, msg} ->
        "request: #{msg}"
    end
  end

  # ── `work` — the agent's own CLI, in-process ────────────────────────────────────────────────────
  # Verbs operate on the agent's /work tree (its VFS host dir). check = compile + ref resolution (the
  # one the runtime gates pushes with); graph/why/near/structure = the code-graph; parse = a file's
  # units. No weave/deploy/login/secret here — those touch the network/creds and aren't an in-sandbox op.
  @work_verbs ~w(check graph structure why near parse syntax help)

  defp run_work(_vfs, [], _perms), do: work_help()

  defp run_work(vfs, [verb | args], perms) do
    cond do
      verb == "help" -> work_help()
      not work_granted?(perms) ->
        "work: '#{verb}' needs an 'exec' or 'commands' grant, not granted to this agent"
      verb not in @work_verbs ->
        "work: unknown verb '#{verb}' — try: #{Enum.join(@work_verbs, ", ")}"
      true ->
        root = Nexus.Agent.Vfs.dir(vfs)
        case verb do
          "check" -> work_check(root)
          "graph" -> work_graph(root)
          "structure" -> work_structure(root)
          "why" -> work_graph_q(root, args, :why)
          "near" -> work_graph_q(root, args, :near)
          "parse" -> work_parse(root, args)
          "syntax" -> work_syntax()
        end
    end
  rescue
    e -> "work: error — #{Exception.message(e)}"
  end

  # `work` is a code/compile capability over the agent's own tree — gate it like exec, not fs-read.
  defp work_granted?(nil), do: true
  defp work_granted?(%{grant: grant}) when is_list(grant), do: Enum.any?(~w(exec commands work), &(&1 in grant))
  defp work_granted?(_), do: true

  defp work_help do
    """
    work — compile + analyze the .work tree in /work (in-process):
      work check            compile-check every unit + resolve all [[refs]]/imports (what the push gate runs)
      work graph            the code graph: unit count, edges, dangling refs
      work structure        the units in /work, grouped by kind
      work why <name>       who depends on <name> (reverse deps)
      work near <name>      <name>'s immediate edges (in + out)
      work parse <file>     the parsed units of one .work file
      work syntax           minimal valid .work syntax for the core kinds (read this BEFORE authoring)
    """
  end

  # A minimal VALID server unit (atom name, `def` functions). Authored here so the cheat-sheet and the
  # test compile the exact same thing — if this stops compiling, the test fails before agents are misled.
  @syntax_server "server :greeter do\n  def hello, do: \"hi\"\nend\n"
  # A minimal VALID resource unit (Capitalized name; fields are `name :type`, NOT `field :name`).
  @syntax_resource "resource Campaigns do\n  name :text\n  status :text\n  owner :text\nend\n"

  @doc false
  def syntax_examples, do: %{server: @syntax_server, resource: @syntax_resource}

  defp work_syntax do
    """
    .work syntax — prose narrates; `do … end` blocks run. The FIRST word names the kind. Minimal valid forms:

    # A server unit — server-side Elixir; behaviour is `def` functions:
    #{@syntax_server}
    # A resource unit — a persisted, typed table. Name is Capitalized; each field is `name :type`
    # (types: :text :int :money :bool :json …). NOT `field :name`:
    #{@syntax_resource}
    # A plain function unit:
    def add(a, b), do: a + b

    Other kinds you'll see: client (browser island), hook (match an #event → effects), flow (ordered steps),
    agent (prompt+tools+grant). To learn one from a real file: `work parse <some-file.work>`.

    Write a file with redirection — `printf '…' > dir/file.work` (the `>` auto-creates dirs; no mkdir needed),
    or a heredoc: `cat > f.work <<EOF … EOF`. After authoring, ALWAYS run `work check` to confirm it compiles.
    """
  end

  # `work check` — the real compile gate: Nexus.Compile.check (beam/syntax/unit compile) + Nexus.Graph.check
  # (dangling backlinks/edges). The SAME logic that gates a git push, so an agent can self-check before it ships.
  defp work_check(root) do
    c = Nexus.Compile.check(root)
    g = Nexus.Graph.build_dir(root) |> Nexus.Graph.check()

    errs =
      Enum.map(c.errors, fn e -> "  ✗ #{e.kind} #{e.name || "?"} — #{e.reason}" end) ++
        Enum.map(g.dangling_backlinks, fn {path, l} ->
          # `l` may already carry its [[ ]] brackets — normalize so we render exactly one pair, never [[[[…]]]].
          label = l |> to_string() |> String.trim() |> String.trim_leading("[") |> String.trim_trailing("]")
          "  ✗ dangling [[#{label}]] in #{Path.relative_to(path, root)}"
        end) ++
        Enum.map(g.dangling_edges, fn e -> "  ✗ unresolved ref #{e.from} → #{e.to}" end)

    ok? = c.ok? and g.ok
    head = if ok?, do: "work check: OK", else: "work check: #{length(errs)} problem(s)"
    skipped = if c.skipped == [], do: "", else: "\n  (#{length(c.skipped)} wasm/client unit(s) checked at build, not here)"
    "#{head} — #{g.nodes} unit(s), #{g.edges} edge(s)" <> skipped <>
      if(errs == [], do: "", else: "\n" <> Enum.join(errs, "\n"))
  end

  defp work_graph(root) do
    g = Nexus.Graph.build_dir(root)
    chk = Nexus.Graph.check(g)
    "work graph: #{map_size(g.nodes)} unit(s), #{length(g.edges)} edge(s), " <>
      "#{length(chk.dangling_backlinks) + length(chk.dangling_edges)} dangling ref(s)"
  end

  defp work_structure(root) do
    g = Nexus.Graph.build_dir(root)

    # g.nodes is keyed BY name (name => node); the name is the map key, not a field on the node.
    g.nodes
    |> Enum.group_by(fn {_name, n} -> Map.get(n, :kind) || "?" end, fn {name, _n} -> name end)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {kind, names} ->
      "#{kind} (#{length(names)}): #{names |> Enum.sort() |> Enum.join(", ")}"
    end)
    |> case do
      "" -> "work structure: no units in /work"
      s -> s
    end
  end

  defp work_graph_q(_root, [], q), do: "work #{q}: usage: work #{q} <unit-name>"

  defp work_graph_q(root, [name | _], :why) do
    case Nexus.Graph.build_dir(root) |> Nexus.Graph.why(name) do
      [] -> "work why #{name}: nothing depends on it (or no such unit)"
      deps -> "work why #{name}: #{Enum.join(deps, ", ")}"
    end
  end

  defp work_graph_q(root, [name | _], :near) do
    case Nexus.Graph.build_dir(root) |> Nexus.Graph.near(name) do
      [] -> "work near #{name}: no edges (or no such unit)"
      edges -> "work near #{name}:\n" <> Enum.map_join(edges, "\n", fn e -> "  #{e.from} → #{e.to}" end)
    end
  end

  # Sanitize a path to a safe rel path under /work (drop a leading /work//, and any `..` traversal).
  defp safe_rel(file) do
    file
    |> String.replace_prefix("/work/", "")
    |> String.replace_prefix("/", "")
    |> Path.split()
    |> Enum.reject(&(&1 in ["..", "."]))
    |> Path.join()
  end

  defp work_parse(_root, []), do: "work parse: usage: work parse <file.work>"

  defp work_parse(root, [file | _]) do
    path = Path.join(root, safe_rel(file))

    if File.exists?(path) do
      units = path |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code))
      case units do
        [] -> "work parse #{file}: no code units (prose-only)"
        _ -> "work parse #{file}: " <> Enum.map_join(units, ", ", fn u -> "#{u.kind} #{u.name}" end)
      end
    else
      "work parse: no such file: #{file}"
    end
  end

  # `image|video|speak` — run a generator model and return the asset as markdown the chat can render.
  # Gated on the matching generator toolkit being active for this run (perms.caps). `--model <id>` and
  # `--lang <code>` pass through; the rest of the args (or stdin) is the prompt.
  defp run_generate(cmd, args, stdin, perms) do
    toolkit = @gen_toolkit[cmd]
    modality = @gen_modality[cmd]

    cond do
      not gen_granted?(perms, toolkit) ->
        "#{cmd}: the '#{toolkit}' capability isn't active for this run — enable it to generate #{modality}"

      true ->
        {model, rest} = take_flag(args, "--model")
        prompt = case Enum.join(rest, " ") |> String.trim() do
                   "" -> String.trim(stdin || "")
                   p -> p
                 end
        tenant = (is_map(perms) && perms[:tenant]) || "default"
        opts = if model, do: [model: model], else: []

        case Nexus.Generator.run(modality, prompt, tenant, opts) do
          {:ok, %{url: url, model: m}} ->
            label = "generated #{modality} (#{m})"
            case modality do
              "image" -> "#{cmd}: done → ![#{label}](#{url})\n#{url}"
              _ -> "#{cmd}: done → [#{label}](#{url})\n#{url}"
            end

          {:error, reason} ->
            "#{cmd}: generation failed — #{reason}"
        end
    end
  end

  # A generator command is permitted when perms is unrestricted (nil) OR the toolkit is in the run's
  # active capabilities. (Capability selection is surfaced into perms by the agent loop.)
  defp gen_granted?(nil, _toolkit), do: true
  defp gen_granted?(perms, toolkit) when is_map(perms) do
    case perms[:caps] do
      caps when is_list(caps) -> toolkit in caps
      _ -> false
    end
  end

  # Pull `--flag <value>` out of an arg list; returns `{value | nil, remaining_args}`.
  defp take_flag(args, flag) do
    case Enum.split_while(args, &(&1 != flag)) do
      {before, [^flag, value | rest]} -> {value, before ++ rest}
      _ -> {nil, args}
    end
  end

  # Permission gate. nil perms = unrestricted. Builtins (kits/help) always allowed. Web commands need
  # a web/net/browse grant. Any other command's KIT must be in the agent's tools.
  # Only the host-brokered WEB commands are gated here (they reach the host network) — needs a web grant.
  # Shell commands run sandboxed on Wasmer (the /work mount is their boundary), so they aren't kit-gated.
  defp permit(_cmd, nil), do: :ok

  defp permit(cmd, perms) when is_map(perms) do
    grant = Map.get(perms, :grant, [])

    if cmd in @web_cmds and not web_granted?(grant),
      do: {:deny, "bash: '#{cmd}' needs web access, not granted to this agent"},
      else: :ok
  end

  defp web_granted?(nil), do: true
  defp web_granted?(grant) when is_list(grant), do: Enum.any?(~w(web net browse), &(&1 in grant))
  defp web_granted?(_), do: true

  defp dispatch(vfs, cmd, args, _stdin) do
    case cmd do
      # web access is HOST-BROKERED (wasm has no sockets) — `fetch <url>` and `scrape <url>` go
      # through Nexus.Dock.fetch (SSRF-safe: loopback/private blocked, https). curl-class.
      "fetch" -> web_fetch(List.first(args))
      # scrape/render <url> → the page as MARKDOWN via the cheap no-wasm Floki extract (default),
      # auto-escalating to the Blitz wasm render when the extract is thin / `--render` / `--js`.
      "scrape" -> web_render(args)
      "render" -> web_render(args)
      # in-wasm Blitz render: screenshot <url> [out.png] → a PNG in /work.
      "screenshot" -> web_screenshot(vfs, args)
      # web search → ranked results via the registered :search provider (keyless metasearch by
      # default, a keyed API in cloud). Numbered title + url + snippet, ready for the agent to scrape.
      "search" -> web_search(args)
      # Tier-1 computer-use: operate a site by semantic action (browser-use model).
      "navigate" -> nav_result(Nexus.Browse.Session.navigate(List.first(args) || ""))
      "links" -> format_session(Nexus.Browse.Session.current(), :links)
      "forms" -> format_session(Nexus.Browse.Session.current(), :forms)
      "click" -> nav_result(Nexus.Browse.Session.click(List.first(args) || ""))
      "fill" -> fill_result(args)
      "submit" -> nav_result(Nexus.Browse.Session.submit(submit_index(args)))
      # Only @builtins reach dispatch (run_segment routes kit commands straight to exec/2); unreachable.
      _ -> "bash: #{cmd}: command not found"
    end
  end

  # `scrape [--render|--js] <url>` — DEFAULT: cheap Floki DOM-extract → markdown, pure BEAM, no wasm
  # (most reads need text+links, not a CSS layout). A thin extract (JS shell) auto-escalates to Blitz;
  # `--render` forces the CSS render, `--js` additionally runs the page's JavaScript.
  defp web_render(args) do
    {js, rest} = take_js_flag(args, :auto)
    force = "--render" in rest
    rest = rest -- ["--render"]
    opts = js ++ if(force or js != [], do: [render: true], else: [])

    case List.first(rest) do
      nil -> "render: usage: scrape [--render|--js] <url>"
      url ->
        case Nexus.Browse.read(url, opts) do
          {:ok, %{markdown: md}} when is_binary(md) and md != "" -> md
          {:ok, %{text: t}} when is_binary(t) and t != "" -> t
          # last-resort tag-strip if even fetch+extract yielded nothing
          _ -> url |> web_fetch() |> html_to_text()
        end
    end
  end

  # `search <query>` — web search through the registered :search provider → a numbered result list.
  defp web_search([]), do: "search: usage: search <query>"

  defp web_search(args) do
    query = Enum.join(args, " ")

    case Nexus.Browse.search(query) do
      {:ok, []} ->
        "search: no results for #{inspect(query)}"

      {:ok, results} ->
        results
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {%{title: t, url: u} = r, i} ->
          snippet = Map.get(r, :snippet, "")
          "#{i}. #{t}\n   #{u}" <> if(snippet != "", do: "\n   #{snippet}", else: "")
        end)

      {:error, {:no_provider, :search}} ->
        "search: no search provider configured (set deploy search=…)"

      {:error, reason} ->
        "search: failed (#{inspect(reason) |> String.slice(0, 80)})"
    end
  end

  # Pull a `--js` flag → render opts selecting `engine` (default `:auto` — fast-first, escalate to the
  # heavy JS engine only when the fast render is thin, keep the richer result; never regress).
  defp take_js_flag(args, engine) do
    if "--js" in args, do: {[engine: engine], args -- ["--js"]}, else: {[], args}
  end

  # ── Tier-1 computer-use builtins ───────────────────────────────────────────
  defp nav_result({:ok, s}), do: format_session(s, :page)
  defp nav_result({:error, reason}), do: "browse: #{inspect(reason) |> String.slice(0, 100)}"

  defp fill_result([field | rest]) when rest != [] do
    value = Enum.join(rest, " ")
    Nexus.Browse.Session.fill(field, value)
    "fill: #{field} = #{value}"
  end

  defp fill_result(_), do: "fill: usage: fill <field-name> <value>"

  defp submit_index(args) do
    case args do
      [n | _] -> case Integer.parse(n), do: ({i, _} -> i; _ -> 1)
      _ -> 1
    end
  end

  # Render a session for the agent: the page text + numbered actionables (links/forms) to act on.
  defp format_session(s, view) do
    header = if s.url, do: "URL: #{s.url}\n", else: ""

    body =
      case view do
        :page -> String.slice(s.text, 0, 4_000) <> "\n\n" <> actionables(s)
        :links -> link_list(s.links)
        :forms -> form_list(s.forms)
      end

    header <> body
  end

  defp actionables(s) do
    "── LINKS (click <n>) ──\n" <> link_list(Enum.take(s.links, 30)) <>
      (if s.forms == [], do: "", else: "\n── FORMS (fill <name> <value>; submit <n>) ──\n" <> form_list(s.forms))
  end

  defp link_list([]), do: "(none)"
  defp link_list(links) do
    links
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {l, i} -> "#{i}. #{String.slice(l.text, 0, 70)}" end)
  end

  defp form_list([]), do: "(none)"
  defp form_list(forms) do
    forms
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {f, i} ->
      fields = f.fields |> Enum.map_join(", ", & &1.name)
      "#{i}. #{f.method} #{f.action} — fields: #{fields}"
    end)
  end

  defp web_screenshot(_vfs, []), do: "screenshot: usage: screenshot [--js] <url> [out.png]"

  defp web_screenshot(vfs, args) do
    {opts, rest} = take_js_flag(args, :jsdom)
    web_screenshot(vfs, rest, opts)
  end

  defp web_screenshot(_vfs, [], _opts), do: "screenshot: usage: screenshot [--js] <url> [out.png]"

  defp web_screenshot(vfs, [url | rest], opts) do
    out = List.first(rest) || "screenshot.png"

    case Nexus.Browse.screenshot(url, opts) do
      {:ok, png} ->
        Nexus.Agent.Vfs.put(vfs, out, png)
        "screenshot: #{url} -> /work/#{out} (#{byte_size(png)} bytes)"

      {:error, reason} ->
        "screenshot: failed (#{inspect(reason) |> String.slice(0, 80)})"
    end
  end

  defp web_fetch(nil), do: "fetch: usage: fetch <url>"
  defp web_fetch(url) do
    case Nexus.Dock.fetch(url) do
      "" -> "fetch: empty or blocked (#{url})"
      body -> body
    end
  end

  # Strip a page to readable text: drop script/style, tags → spaces, decode common entities,
  # collapse whitespace. Zero-dep (good enough for an agent to read a page).
  defp html_to_text(html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1>}is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s*\n\s*/, "\n\n")
    |> String.trim()
  end

  @entities %{"&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'",
              "&apos;" => "'", "&nbsp;" => " "}
  defp decode_entities(s),
    do: Enum.reduce(@entities, s, fn {e, c}, acc -> String.replace(acc, e, c) end)

  # Returns {output, ok?} — ok from the wasm exit code, so `kit && next` short-circuits like bash.
end
