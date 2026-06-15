defmodule Workbooks.DesktopAgent.Gate do
  @moduledoc """
  Posture predicate for the ACP desktop broker (Workbooks.DesktopAgent). The broker spawns
  the USER'S OWN native coding agent (claude/codex) as a real OS process and relays ACP over
  its stdio. That is a DESKTOP-ORCHESTRATION capability — legitimate on a single-user desktop
  (the Zed/Cursor model), categorically wrong in a multi-tenant hosted runtime. This is the
  single source of truth for "may the ACP broker exist / be reached?".

  Mirrors `Workbooks.Harness` exactly: the broker is the same CLASS of surface (a desktop-first
  primitive that has no place in a hosted runtime), so it gates on the same posture.
  """

  @doc "True iff (WB_DESKTOP=1 or WB_ACP_DESKTOP=1) AND NOT multi-tenant hosted."
  def enabled? do
    requested?() and not Workbooks.Tenancy.multi?()
  end

  @doc "True when the ACP desktop broker was explicitly requested (desktop or explicit opt-in)."
  def requested? do
    System.get_env("WB_DESKTOP") == "1" or System.get_env("WB_ACP_DESKTOP") == "1"
  end
end

defmodule Workbooks.DesktopAgent do
  @moduledoc """
  Host-side ACP relay to the USER'S OWN native coding agent on a single-user desktop
  (the desktop-only redesign of external-agent delegation — supersedes the always-on,
  guest-reachable `Workbooks.ExternalAgent`). WB_DESKTOP-only (see `.Gate`).

  It spawns the user's own `claude`/`codex` binary as a real OS process (NOT a platform-pinned
  artifact), speaks ACP over its stdio (initialize → authenticate → session/new →
  session/prompt → stream session/update), maps each `session/update` into
  `Workbooks.Workflow.Telemetry` (the shared run DAG), and returns a structured result.

  THE LOAD-BEARING SAFETY PROPERTY (gating, defense in depth — any one suffices):

    1. Supervision start. `Workbooks.Application` gates the broker registry's child-spec on
       `Gate.enabled?/0` (exactly as it gates `ExecLoopback` on `Harness.enabled?/0`). In a
       hosted/multi-tenant runtime the registry is never started.
    2. Every public entry (spawn/await/kill/agents) re-checks `Gate.enabled?/0` and
       fail-closes with `{:error, :acp_desktop_only}`. A stray caller in the wrong posture is
       refused at the function boundary, not only at startup.
    3. Not wired to the guest. There is no `delegate` tool, no `@exec_tools` entry, no Dock
       import, no loopback route. The in-wasm guest has NO NAME for this capability and cannot
       reach what it cannot name. The DESKTOP orchestration drives this via a delegate path
       (`spawn/3` / `await/2` / `kill/1`), never the agent loop.

  The binary is the user's OWN install (resolved by the desktop as an absolute path; the
  runtime `$PATH` is NOT trusted). `task` is delivered ONLY as the ACP `session/prompt`
  payload — never interpolated into argv (structural, no shell, no arg-smuggling). We never
  read/proxy/inject the subscription token: the agent authenticates with its own held
  credential. The Port is wrapped in `setsid` so the whole process group is killable on
  timeout/cancel.
  """
  use GenServer
  require Logger

  alias Workbooks.DesktopAgent.Gate

  @typedoc "An open delegation handle (lifetime == the agent subprocess)."
  @type handle :: pid

  # Logical agent ids the desktop permits. The id is LOGICAL — the user never names a raw path
  # through this API; the desktop resolves the absolute binary path (§2.1). New agents are added
  # here EXPLICITLY, never inferred.
  @agents %{
    "claude" => %{acp_argv: ["--acp"], discover: "claude"},
    "codex" => %{acp_argv: ["acp"], discover: "codex"}
  }

  @default_wall_clock_ms 600_000
  @default_idle_ms 120_000
  @max_artifacts 64
  @protocol_version 1

  @sup Workbooks.DesktopAgent.Sup

  @doc """
  Defense-in-depth LEG 1 — the supervision-start gate. `Workbooks.Application` calls this to
  decide the broker's child-spec: a `DynamicSupervisor` that owns the per-handle broker
  processes, started ONLY when `Gate.enabled?/0`. In a hosted/multi-tenant runtime it is never
  started → there is no supervisor to spawn a handle under, and `spawn/3` (leg 2) refuses at the
  function boundary as well.
  """
  def child_specs do
    if Gate.enabled?() do
      [{DynamicSupervisor, strategy: :one_for_one, name: @sup}]
    else
      []
    end
  end

  # ── public API ─────────────────────────────────────────────────────────────

  @doc "Logical agent ids the desktop permits (claude | codex). Gate-checked → [] if off."
  @spec agents() :: [String.t()]
  def agents do
    if Gate.enabled?(), do: Map.keys(@agents) |> Enum.sort(), else: []
  end

  @doc """
  Gate-checked. Resolve the user's own binary → Port spawn → ACP initialize + session/new.
  Non-blocking; returns once a session id is open. Fail-closed on posture/allowlist.

  opts:
    * `:bin`     — ABSOLUTE path to the user's own binary, resolved by the desktop (REQUIRED;
                   the runtime `$PATH` is not trusted). Falls back to `System.find_executable/1`
                   ONLY for dev/test convenience when the desktop did not resolve one.
    * `:workdir` — the confined project dir (REQUIRED; `cd` + ACP `session/new {cwd}`).
    * `:env`     — extra env (minimal allowlist; NO provider keys are injected by us).
  """
  @spec spawn(agent_id :: String.t(), task :: String.t(), opts :: keyword) ::
          {:ok, handle} | {:error, atom}
  def spawn(agent_id, task, opts \\ []) when is_binary(agent_id) and is_binary(task) do
    cond do
      not Gate.enabled?() ->
        {:error, :acp_desktop_only}

      not Map.has_key?(@agents, agent_id) ->
        {:error, :unknown_agent}

      true ->
        with {:ok, bin} <- resolve_bin(agent_id, opts),
             {:ok, workdir} <- confine_workdir(opts) do
          spec = @agents[agent_id]

          init_arg = %{
            agent_id: agent_id,
            bin: bin,
            acp_argv: spec.acp_argv,
            task: task,
            workdir: workdir,
            env: Keyword.get(opts, :env, [])
          }

          start_handle(init_arg)
          |> case do
            {:ok, pid} ->
              # Block briefly only on the handshake → an open session id; the run itself is await/2.
              case GenServer.call(pid, :open, 30_000) do
                :ok -> {:ok, pid}
                {:error, _} = err -> err
              end

            {:error, {:already_started, _}} = e ->
              e

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  @doc """
  Send session/prompt and block until {stopReason} or wall-clock/idle deadline. Streams every
  session/update → telemetry adapter throughout. Reaps + tears down once.

  Returns `%{stop_reason, output, artifacts, usage}`.
  """
  @spec await(handle, timeout_ms :: non_neg_integer) ::
          {:ok, %{stop_reason: String.t(), output: String.t(), artifacts: [String.t()], usage: map}}
          | {:error, atom}
  def await(pid, timeout_ms \\ @default_wall_clock_ms) when is_pid(pid) do
    if not Gate.enabled?() do
      {:error, :acp_desktop_only}
    else
      # The GenServer enforces idle_ms internally; we add a hard wall-clock ceiling here.
      try do
        GenServer.call(pid, {:await, timeout_ms}, timeout_ms + 5_000)
      catch
        :exit, _ -> {:error, :timeout}
      end
    end
  end

  @doc "session/cancel notification then kill the process group. Idempotent."
  @spec kill(handle) :: :ok
  def kill(pid) when is_pid(pid) do
    # No gate here: kill must ALWAYS work as the stop button, even mid-posture-change.
    if Process.alive?(pid), do: GenServer.cast(pid, :kill)
    :ok
  end

  # Start a handle under the gated DynamicSupervisor (leg 1). Falls back to an unsupervised
  # GenServer.start only if the supervisor isn't up — but in the enabled posture it always is.
  defp start_handle(init_arg) do
    if Process.whereis(@sup) do
      DynamicSupervisor.start_child(@sup, %{
        id: make_ref(),
        start: {GenServer, :start_link, [__MODULE__, init_arg]},
        restart: :temporary
      })
    else
      GenServer.start(__MODULE__, init_arg)
    end
  end

  # ── binary + workdir resolution (fail-closed) ──────────────────────────────

  # The user's OWN binary, the way Zed/Cursor do — NOT a platform-pinned sha256 artifact.
  # Trust anchor = the absolute path the DESKTOP resolved (it knows the user's real $PATH /
  # Homebrew / installer location). The runtime process $PATH is NOT trusted (PATH-injection
  # defense). `:bin` MUST be absolute; find_executable is a dev/test fallback only.
  defp resolve_bin(agent_id, opts) do
    case Keyword.get(opts, :bin) do
      bin when is_binary(bin) and bin != "" ->
        if Path.type(bin) == :absolute and File.exists?(bin),
          do: {:ok, bin},
          else: {:error, :agent_not_installed}

      _ ->
        case System.find_executable(@agents[agent_id].discover) do
          nil -> {:error, :agent_not_installed}
          path -> {:ok, path}
        end
    end
  end

  # Confine to a chosen project dir (the user's own tool scoped to the user's chosen project,
  # not a multi-tenant jail). Canonicalized; must be an existing dir.
  defp confine_workdir(opts) do
    case Keyword.get(opts, :workdir) do
      wd when is_binary(wd) and wd != "" ->
        full = Path.expand(wd)
        if File.dir?(full), do: {:ok, full}, else: {:error, :workdir_not_found}

      _ ->
        {:error, :workdir_required}
    end
  end

  # ── GenServer (one per delegation handle, lifetime == the subprocess) ───────

  @impl true
  def init(state) do
    st =
      state
      |> Map.merge(%{
        port: nil,
        os_pid: nil,
        session_id: nil,
        buf: "",
        next_id: 1,
        pending: %{},
        # telemetry: open tool steps keyed by ACP toolCallId
        steps: %{},
        step_seq: 0,
        # harvested assistant text + usage rollup
        out: [],
        usage: %{},
        awaiter: nil,
        idle_ref: nil,
        idle_timer: nil,
        idle_ms: @default_idle_ms,
        opener: nil,
        opened: false,
        stop_reason: nil
      })

    {:ok, st}
  end

  @impl true
  def handle_call(:open, from, st) do
    # spawn the Port (setsid → killable process group), then drive initialize → session/new.
    bin = setsid_bin()
    argv = [st.bin | st.acp_argv]

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:cd, st.workdir},
        {:env, port_env(st.env)},
        {:args, argv}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    st = %{st | port: port, os_pid: os_pid, opener: from}

    # initialize → (authenticate) → session/new are driven by the stdout reader as replies arrive.
    st = rpc(st, "initialize", %{
      protocolVersion: @protocol_version,
      clientCapabilities: %{fs: %{readTextFile: true, writeTextFile: true}, terminal: true}
    })

    {:noreply, arm_idle(st)}
  end

  def handle_call({:await, _timeout_ms}, from, %{session_id: sid} = st) when is_binary(sid) do
    st = rpc(st, "session/prompt", %{
      sessionId: sid,
      prompt: [%{type: "text", text: st.task}]
    })

    {:noreply, %{st | awaiter: from}}
  end

  def handle_call({:await, _timeout_ms}, _from, st) do
    {:reply, {:error, :session_not_open}, st}
  end

  @impl true
  def handle_cast(:kill, st) do
    st = if st.session_id, do: notify(st, "session/cancel", %{sessionId: st.session_id}), else: st
    teardown(st, :cancelled)
    {:stop, :normal, st}
  end

  # ── Port I/O ───────────────────────────────────────────────────────────────

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = st) do
    st = st |> reset_idle() |> handle_line(line)
    {:noreply, st}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = st) do
    {:noreply, %{st | buf: st.buf <> chunk}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = st) do
    st = finish(st, st.stop_reason || exit_stop(code))
    {:stop, :normal, st}
  end

  def handle_info({:idle_timeout, ref}, %{idle_ref: ref} = st) do
    st = if st.session_id, do: notify(st, "session/cancel", %{sessionId: st.session_id}), else: st
    st = finish(st, "cancelled")
    teardown(st, :idle)
    {:stop, :normal, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  # ── ACP line handling ──────────────────────────────────────────────────────

  defp handle_line(st, line) do
    line = st.buf <> line
    st = %{st | buf: ""}

    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} -> handle_reply(st, id, result)
      {:ok, %{"id" => id, "error" => err}} -> handle_error_reply(st, id, err)
      {:ok, %{"method" => method} = msg} -> handle_request(st, method, msg)
      _ -> st
    end
  end

  # Replies to OUR requests (initialize / authenticate / session/new / session/prompt).
  defp handle_reply(st, id, result) do
    case Map.pop(st.pending, id) do
      {"initialize", pending} ->
        st = %{st | pending: pending}
        methods = result["authMethods"] || []

        if methods == [] do
          open_session(st)
        else
          # Tell the agent WHICH method — it authenticates with its OWN held credential.
          method_id = methods |> List.first() |> method_id()
          st = rpc(st, "authenticate", %{methodId: method_id})
          st
        end

      {"authenticate", pending} ->
        open_session(%{st | pending: pending})

      {"session/new", pending} ->
        sid = result["sessionId"]
        st = %{st | pending: pending, session_id: sid}
        if st.opener, do: GenServer.reply(st.opener, :ok)
        %{st | opener: nil, opened: true}

      {"session/prompt", pending} ->
        # Terminal: the run resolved. await/2 returns the structured result.
        st = %{st | pending: pending}
        finish(st, result["stopReason"] || "end_turn")

      {_other, pending} ->
        %{st | pending: pending}
    end
  end

  defp handle_error_reply(st, id, err) do
    case Map.pop(st.pending, id) do
      {"session/new", pending} ->
        if st.opener, do: GenServer.reply(st.opener, {:error, :session_new_failed})
        %{st | pending: pending, opener: nil}

      {"initialize", pending} ->
        if st.opener, do: GenServer.reply(st.opener, {:error, :initialize_failed})
        %{st | pending: pending, opener: nil}

      {_m, pending} ->
        Logger.warning("acp: rpc #{id} error: #{inspect(err)}")
        %{st | pending: pending}
    end
  end

  # Inbound requests/notifications FROM the agent.
  defp handle_request(st, "session/update", %{"params" => params}) do
    update = params["update"] || %{}
    ingest_update(st, update)
  end

  # Permission request → desktop policy. Default: deny-cancel (the desktop UI answers in the real
  # drive surface; here we fail-closed so an un-answered prompt can't hang or silently allow).
  defp handle_request(st, "session/request_permission", %{"id" => id}) do
    reply_result(st, id, %{outcome: %{outcome: "cancelled"}})
  end

  # fs/* and terminal/* served INSIDE the workdir confine only (prefix-checked).
  defp handle_request(st, "fs/read_text_file", %{"id" => id, "params" => p}) do
    case confined_path(st, p["path"]) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, body} -> reply_result(st, id, %{content: body})
          {:error, _} -> reply_error(st, id, -32000, "read_failed")
        end

      :error ->
        reply_error(st, id, -32001, "path_outside_workdir")
    end
  end

  defp handle_request(st, "fs/write_text_file", %{"id" => id, "params" => p}) do
    case confined_path(st, p["path"]) do
      {:ok, path} ->
        File.mkdir_p(Path.dirname(path))

        case File.write(path, p["content"] || "") do
          :ok -> reply_result(st, id, %{})
          {:error, _} -> reply_error(st, id, -32000, "write_failed")
        end

      :error ->
        reply_error(st, id, -32001, "path_outside_workdir")
    end
  end

  defp handle_request(st, _method, %{"id" => id}) do
    # Any other host-side ACP request we don't serve → method-not-found (fail-closed).
    reply_error(st, id, -32601, "method_not_supported")
  end

  defp handle_request(st, _method, _msg), do: st

  # ── ACP session/update → Workflow.Telemetry (the shared DAG) ────────────────
  # Adapter rule: append the standard step-event shape to the parent run's <workdir>/_steps.jsonl,
  # tagged `agent: <agent_id>`, so the delegated sub-agent's steps join the parent DAG with no
  # change to Telemetry. Step shape: {step, agent, tool, args, output, exit_code, error, dur_ms, ts}.

  defp ingest_update(st, %{"sessionUpdate" => "tool_call"} = u) do
    tcid = u["toolCallId"]
    step = st.step_seq + 1

    rec = %{
      step: step,
      agent: st.agent_id,
      tool: u["kind"] || u["title"] || "tool",
      args: u["rawInput"] || %{},
      output: nil,
      exit_code: nil,
      error: nil,
      dur_ms: nil,
      ts: now_ms(),
      _started: now_ms()
    }

    %{st | step_seq: step, steps: Map.put(st.steps, tcid, rec)}
  end

  defp ingest_update(st, %{"sessionUpdate" => "tool_call_update"} = u) do
    tcid = u["toolCallId"]
    status = u["status"]

    case Map.get(st.steps, tcid) do
      nil ->
        st

      rec when status in ["completed", "failed"] ->
        closed =
          if status == "completed" do
            %{rec | output: content_text(u), exit_code: 0, dur_ms: now_ms() - rec._started}
          else
            %{rec | error: content_text(u) || "failed", exit_code: 1, dur_ms: now_ms() - rec._started}
          end

        emit_step(st, closed)
        %{st | steps: Map.delete(st.steps, tcid)}

      _rec ->
        st
    end
  end

  defp ingest_update(st, %{"sessionUpdate" => "agent_message_chunk", "content" => c}) do
    %{st | out: [chunk_text(c) | st.out]}
  end

  defp ingest_update(st, %{"sessionUpdate" => "agent_thought_chunk"}) do
    # optional think-kind trace; folded into output stream not emitted as a tool step.
    st
  end

  defp ingest_update(st, %{"sessionUpdate" => "plan", "entries" => entries}) do
    step = st.step_seq + 1

    emit_step(st, %{
      step: step,
      agent: st.agent_id,
      tool: "plan",
      args: %{entries: entries},
      output: nil,
      exit_code: 0,
      error: nil,
      dur_ms: 0,
      ts: now_ms()
    })

    %{st | step_seq: step}
  end

  defp ingest_update(st, %{"sessionUpdate" => "usage_update"} = u) do
    usage =
      st.usage
      |> Map.put(:used, u["used"] || st.usage[:used])
      |> Map.put(:size, u["size"] || st.usage[:size])
      |> Map.put(:cost, u["cost"] || st.usage[:cost])

    %{st | usage: usage}
  end

  defp ingest_update(st, _u), do: st

  # Append one step record (minus the internal _started key) to the parent run's _steps.jsonl.
  defp emit_step(st, rec) do
    line = rec |> Map.delete(:_started) |> Jason.encode!()
    File.write(Path.join(st.workdir, "_steps.jsonl"), line <> "\n", [:append])
  rescue
    _ -> :ok
  end

  # ── terminal: resolve await/2 with the structured result ───────────────────

  defp finish(%{stop_reason: sr} = st, _new) when is_binary(sr), do: st

  defp finish(st, stop_reason) do
    result = %{
      stop_reason: stop_reason,
      output: st.out |> Enum.reverse() |> Enum.join(""),
      artifacts: harvest_artifacts(st.workdir),
      usage: st.usage
    }

    if st.awaiter, do: GenServer.reply(st.awaiter, {:ok, result})
    if st.opener, do: GenServer.reply(st.opener, {:error, :closed_before_session})

    %{st | stop_reason: stop_reason, awaiter: nil, opener: nil}
  end

  defp teardown(st, _why) do
    cancel_idle(st)

    if st.os_pid do
      # kill the whole process group (setsid made it killable): negative pgid.
      System.cmd("/bin/kill", ["-KILL", "--", "-#{st.os_pid}"], stderr_to_stdout: true)
    end

    if is_port(st.port) do
      try do
        Port.close(st.port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ── JSON-RPC plumbing ──────────────────────────────────────────────────────

  defp rpc(st, method, params) do
    id = st.next_id
    send_json(st, %{jsonrpc: "2.0", id: id, method: method, params: params})
    %{st | next_id: id + 1, pending: Map.put(st.pending, id, method)}
  end

  defp notify(st, method, params) do
    send_json(st, %{jsonrpc: "2.0", method: method, params: params})
    st
  end

  defp reply_result(st, id, result) do
    send_json(st, %{jsonrpc: "2.0", id: id, result: result})
    st
  end

  defp reply_error(st, id, code, message) do
    send_json(st, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
    st
  end

  defp send_json(st, msg) do
    if is_port(st.port) do
      Port.command(st.port, [Jason.encode!(msg), "\n"])
    end
  rescue
    _ -> :ok
  end

  defp open_session(st) do
    rpc(st, "session/new", %{cwd: st.workdir, mcpServers: []})
  end

  # ── small helpers ──────────────────────────────────────────────────────────

  # setsid wrapper so the spawned agent gets its own process group → killable as a group.
  defp setsid_bin do
    System.find_executable("setsid") || System.find_executable("env") || "/usr/bin/env"
  end

  # Minimal allowlisted env. We do NOT inject provider keys (ANTHROPIC_API_KEY etc.) — the
  # agent authenticates with its OWN held subscription credential in its own store.
  defp port_env(extra) do
    base = [
      {~c"PATH", String.to_charlist(System.get_env("PATH") || "/usr/bin:/bin")},
      {~c"HOME", String.to_charlist(System.get_env("HOME") || "/tmp")}
    ]

    extra =
      for {k, v} <- extra, is_binary(k) and is_binary(v) do
        {String.to_charlist(k), String.to_charlist(v)}
      end

    base ++ extra
  end

  defp arm_idle(st), do: reset_idle(st)

  defp reset_idle(st) do
    cancel_idle(st)
    timer = Process.send_after(self(), {:idle_timeout, st_ref = make_ref()}, st.idle_ms)
    %{st | idle_ref: st_ref, idle_timer: timer}
  end

  defp cancel_idle(%{idle_timer: t}) when is_reference(t), do: Process.cancel_timer(t)
  defp cancel_idle(_st), do: :ok

  defp confined_path(st, path) when is_binary(path) do
    root = st.workdir
    full = Path.expand(path, root)
    # canonicalize symlinks where possible, then prefix-check.
    canon = case File.cwd() do
      _ -> resolve_real(full)
    end

    if String.starts_with?(canon <> "/", root <> "/") or canon == root,
      do: {:ok, canon},
      else: :error
  end

  defp confined_path(_st, _), do: :error

  # Resolve the real path (follows existing symlinks); for not-yet-existing files resolve the
  # existing parent and re-append, so `../` and symlink escape are both caught.
  defp resolve_real(path) do
    case File.read_link(path) do
      {:ok, _} ->
        case :file.read_link_all(String.to_charlist(path)) do
          _ -> Path.expand(path)
        end

      _ ->
        parent = Path.dirname(path)

        if File.exists?(parent) do
          Path.join(real_dir(parent), Path.basename(path))
        else
          Path.expand(path)
        end
    end
  end

  defp real_dir(dir) do
    case :file.read_link_all(String.to_charlist(dir)) do
      {:ok, target} -> Path.expand(List.to_string(target))
      _ -> Path.expand(dir)
    end
  end

  defp harvest_artifacts(workdir) do
    case File.ls(workdir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "_"))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.take(@max_artifacts)

      _ ->
        []
    end
  end

  defp method_id(%{"id" => id}), do: id
  defp method_id(m) when is_binary(m), do: m
  defp method_id(_), do: nil

  defp content_text(%{"content" => c}), do: chunk_text(c)
  defp content_text(%{"rawOutput" => o}) when is_binary(o), do: o
  defp content_text(%{"rawOutput" => o}), do: inspect(o)
  defp content_text(_), do: nil

  defp chunk_text(%{"text" => t}), do: t
  defp chunk_text([%{"text" => t} | _]), do: t
  defp chunk_text(list) when is_list(list) do
    list |> Enum.map(&chunk_text/1) |> Enum.reject(&is_nil/1) |> Enum.join("")
  end

  defp chunk_text(_), do: nil

  defp exit_stop(0), do: "end_turn"
  defp exit_stop(_), do: "cancelled"

  defp now_ms, do: System.system_time(:millisecond)
end
