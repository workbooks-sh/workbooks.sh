defmodule Workbooks.HarnessSession do
  @moduledoc """
  PERSISTENT pooled StarlingMonkey instance (SLICE 2 / wb-b9xv.10 / wb-b9xv.11 — the REAL FIX).

  `Workbooks.JsEngine.eval/2` is STRUCTURALLY one-shot: every call does
  `Wasmex.Components.start_link → call_function("run") → Process.exit(pid,:normal)` in an `after`, so the
  JS heap, globals, function definitions, and event loop are torn down per call (a ~0.65s cold-start tax
  EVERY round-trip). A real *headless harness turn* holds conversation state, a tool registry, an fs working
  tree, and (across turns) all of that live between many tool-call round-trips — the one-shot eval cannot do
  it, and the "serialize-state-in/out across re-evals" workaround is lossy (non-serializable handles, torn-
  down in-flight async) and re-pays cold-start every hop.

  THIS module is the right fix the map gated SLICE 2 on: a GenServer keyed by session id that holds ONE live
  `Wasmex.Components` pid, drops the per-call teardown, and calls `run(src)` REPEATEDLY against the SAME live
  SpiderMonkey heap — so globals/handles/event-loop survive between tool round-trips. The cold-start tax moves
  to once-per-session (the whole point).

  EMPIRICALLY PROVEN (the map flagged this as unprobed/INFERRED):
    * heap + globals persist across `run()` calls — `globalThis.__x` accumulates 1→2→3 across calls;
    * a function defined in one `run()` is callable in the next;
    * async `run()` (await setTimeout/Promise) settles per-call AND its heap mutations persist;
    * `fetch` is available and drivable re-entrantly (the brokered tool loop + LLM fetch run on it).

  COSTS (the map's real-fix accounting, now operationalized):
    1. MEMORY — each live SM instance is a ~10MB+ resident heap held for the session lifetime (vs reclaimed
       per call). Mitigation: `@idle_ms` idle-timeout eviction (the GenServer self-terminates after inactivity)
       + a per-registry session cap upstream. A pool/registry is a thin layer over this (one GenServer per
       session id); not built here beyond start/lookup, because the THESIS only needs ONE live session.
    2. ISOLATION — a resident instance accumulates state, so a crash/poison in one turn taints the session.
       Mitigation: `recycle/1` tears the pid down and re-instantiates a fresh heap (same session id) — the
       caller recycles on a hard error. (A future poison-detector can auto-recycle.)
    3. EVENT-LOOP RE-ENTRY — the actual uncertainty was whether `run()` is re-callable on a LIVE instance with
       the event loop mid-flight. PROVEN yes: each `run()` is an async export the host awaits to settle; the
       instance's store + event loop stay drivable across calls (Wasmex/wasmtime hold the store between calls).
    4. The cold-start tax is paid ONCE at `start_link`, then amortized over every turn round-trip.
  """
  use GenServer
  require Logger

  alias Workbooks.{JsEngine, ExecLoopback}

  # idle eviction: a session with no `eval` for this long self-terminates to reclaim the ~10MB heap.
  @idle_ms 5 * 60_000
  @default_timeout 30_000

  defstruct [:wasm, :sm_pid, :session_id, :exec_token, :grant, last_active_ms: 0]

  # ── public API ───────────────────────────────────────────────────────────────────────────────

  @doc """
  Start a persistent harness session. `opts`:
    * `:session_id` — id for this session (default: a random ref); also the registered name.
    * `:exec`       — exec/llm grant `[allow: true, commands: …, principal: …]`. Mints ONE long-lived
                      ExecLoopback token for the SESSION (revoked on terminate), so the resident harness can
                      make many tool calls + LLM fetches across the turn without re-minting per round-trip.
  Returns `{:ok, pid}`. The cold-start (instantiate the ~10MB SM component) is paid HERE, once.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name(Keyword.get(opts, :session_id)))
  end

  @doc "Look up a session pid by id (nil if not registered/started)."
  def whereis(id) do
    case Registry.lookup(__MODULE__.Registry, id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Evaluate `src` on this session's LIVE heap (re-entrant `run(src)` — globals/handles/event-loop persist).
  Returns `{:ok, result_string}` | `{:error, why}`. `:timeout` ms (default #{@default_timeout}).
  """
  def eval(pid, src, opts \\ []) when is_binary(src) do
    GenServer.call(pid, {:eval, src, opts}, Keyword.get(opts, :timeout, @default_timeout) + 5_000)
  end

  @doc """
  Drive ONE non-interactive harness turn on the resident harness: `prompt` in -> the harness fetches the
  LLM endpoint, runs the model's tool_use over child_process (brokered), feeds the tool_result back, fetches
  again, and returns the final text answer. The harness's conversation state persists on the live heap, so
  consecutive `turn/2` calls accumulate context (proven by `__harness.turns`/`.messages.length` growing).
  `run()` awaits the returned thenable, so the answer string comes straight back. Returns `{:ok, answer}`.
  """
  def turn(pid, prompt, opts \\ []) when is_binary(prompt) do
    src = "globalThis.__harness.turn(" <> Jason.encode!(prompt) <> ")"
    eval(pid, src, opts)
  end

  @doc "The session's long-lived exec/llm token (for the boot seam), or nil if no grant."
  def exec_token(pid), do: GenServer.call(pid, :exec_token)

  @doc """
  Install the Node platform (require/process/Buffer + the SM child_process shim + the exec & LLM seams) on
  this session's LIVE heap, ONCE. `opts`: `:env` (process.env map), `:argv`. After this, every `eval/2`
  shares those globals (the resident-harness shape). The exec/LLM token is the SESSION token minted at
  `start_link` (so many tool/LLM round-trips reuse one grant). Then evals the `harness_js` so the resident
  harness object is installed and survives subsequent turns. Returns the boot eval result.
  """
  def boot(pid, harness_js, opts \\ []) when is_binary(harness_js) do
    GenServer.call(pid, {:boot, harness_js, opts}, @default_timeout)
  end

  @doc "Tear down + re-instantiate a fresh SM heap under the same session id (poison recovery, cost #2)."
  def recycle(pid), do: GenServer.call(pid, :recycle, @default_timeout)

  @doc "Stop the session (revokes the token, frees the ~10MB heap)."
  def stop(pid), do: GenServer.stop(pid, :normal)

  # Name via the session Registry when an id is given AND the Registry is running; otherwise unnamed (the
  # caller holds the pid — adequate for the THESIS, which drives ONE session by pid).
  defp name(nil), do: nil

  defp name(id) do
    if Process.whereis(__MODULE__.Registry),
      do: {:via, Registry, {__MODULE__.Registry, id}},
      else: nil
  end

  # ── GenServer ────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id, make_ref())
    exec_opts = Keyword.get(opts, :exec, nil)

    with {:ok, wasm} <- JsEngine.build_host(),
         {:ok, sm_pid} <- instantiate(wasm) do
      {exec_token, grant} = maybe_mint(exec_opts)

      {:ok,
       %__MODULE__{
         wasm: wasm,
         sm_pid: sm_pid,
         session_id: session_id,
         exec_token: exec_token,
         grant: grant,
         last_active_ms: now()
       }, @idle_ms}
    else
      {:error, reason} -> {:stop, {:harness_session_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:eval, src, opts}, _from, st) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    res = Wasmex.Components.call_function(st.sm_pid, "run", [src], timeout)
    {:reply, res, %{st | last_active_ms: now()}, @idle_ms}
  end

  def handle_call(:exec_token, _from, st), do: {:reply, st.exec_token, st, @idle_ms}

  def handle_call({:boot, harness_js, opts}, _from, st) do
    # exec seam = the SESSION token (reused across every round-trip this session makes). The LLM endpoint
    # shares the same pinned sentinel host + token gate, exposed to the harness as __wbHarness.{llmUrl,token}.
    exec_seam =
      if st.exec_token, do: %{"url" => ExecLoopback.sentinel_url(), "token" => st.exec_token}, else: nil

    boot_opts =
      [env: Keyword.get(opts, :env, %{}), argv: Keyword.get(opts, :argv, ["node", "harness"])]
      |> then(fn o -> if exec_seam, do: Keyword.put(o, :exec_seam, exec_seam), else: o end)

    case JsEngine.node_boot_payload(boot_opts) do
      {:ok, boot_js, _token} ->
        # 1) install the Node platform (require/process/Buffer/__wbExec) on the live heap;
        # 2) expose the LLM seam the harness reads;
        # 3) eval the harness JS (installs the resident harness object).
        llm_seam =
          if st.exec_token,
            do: Jason.encode!(%{"llmUrl" => ExecLoopback.llm_url(), "token" => st.exec_token}),
            else: "null"

        platform = boot_js <> "\nglobalThis.__wbHarness=" <> llm_seam <> ";\n'platform-ready'"

        with {:ok, _} <- Wasmex.Components.call_function(st.sm_pid, "run", [platform], @default_timeout),
             {:ok, res} <- Wasmex.Components.call_function(st.sm_pid, "run", [harness_js], @default_timeout) do
          {:reply, {:ok, res}, %{st | last_active_ms: now()}, @idle_ms}
        else
          other -> {:reply, normalize(other), st, @idle_ms}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, st, @idle_ms}
    end
  end

  def handle_call(:recycle, _from, st) do
    if Process.alive?(st.sm_pid), do: Process.exit(st.sm_pid, :normal)

    case instantiate(st.wasm) do
      {:ok, sm_pid} -> {:reply, :ok, %{st | sm_pid: sm_pid, last_active_ms: now()}, @idle_ms}
      {:error, reason} -> {:stop, {:recycle_failed, reason}, {:error, reason}, st}
    end
  end

  @impl true
  def handle_info(:timeout, st) do
    Logger.debug("harness-session #{inspect(st.session_id)} idle-evicted (freed resident SM heap)")
    {:stop, :normal, st}
  end

  @impl true
  def terminate(_reason, st) do
    if st.exec_token, do: ExecLoopback.revoke(st.exec_token)
    if st.sm_pid && Process.alive?(st.sm_pid), do: Process.exit(st.sm_pid, :normal)
    :ok
  end

  # ── internals ────────────────────────────────────────────────────────────────────────────────

  # The whole point: NO `after Process.exit`. Keep the pid alive for the session's lifetime.
  defp instantiate(wasm) do
    case Wasmex.Components.start_link(%{
           path: wasm,
           wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true}
         }) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:instantiate_failed, reason}}
    end
  end

  defp maybe_mint(nil), do: {nil, nil}

  defp maybe_mint(exec_opts) when is_list(exec_opts) do
    grant = %{
      allow: Keyword.get(exec_opts, :allow, false),
      commands: Keyword.get(exec_opts, :commands, :all),
      principal: Keyword.get(exec_opts, :principal),
      depth: Keyword.get(exec_opts, :depth, 0),
      # SLICE 3: per-(user, provider) creds scope for dock.creds.{get,put}. The harness can only touch the
      # user+provider the host granted — one tenant's grant never reaches another's keychain blob.
      creds_scope: Keyword.get(exec_opts, :creds_scope, nil)
    }

    {ExecLoopback.mint(grant), grant}
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, _} = err), do: err
  defp normalize(other), do: {:error, other}

  defp now, do: System.monotonic_time(:millisecond)
end
