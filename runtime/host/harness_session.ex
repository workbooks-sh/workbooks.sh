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

  defstruct [:wasm, :sm_pid, :session_id, :exec_token, :grant, :workdir, last_active_ms: 0]

  # ── public API ───────────────────────────────────────────────────────────────────────────────

  @doc """
  Start a persistent harness session. `opts`:
    * `:session_id` — id for this session (default: a random ref); also the registered name.
    * `:exec`       — exec/llm grant `[allow: true, commands: …, principal: …]`. Mints ONE long-lived
                      ExecLoopback token for the SESSION (revoked on terminate), so the resident harness can
                      make many tool calls + LLM fetches across the turn without re-minting per round-trip.
    * `:fs`         — fs grant `[workdir: "/abs/dir", principal: …]`. Folds a confined `:workdir` into the
                      SAME session token's grant so `require('node:fs')` / `'fs/promises'` work on the resident
                      heap, routed over the pinned sentinel to `/__wb/fs`, confined to the workdir. The fs and
                      exec/LLM caps ride ONE token (one mint, one revoke) for the whole session.
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
    fs_opts = Keyword.get(opts, :fs, nil)

    {exec_token, grant, workdir} = maybe_mint(exec_opts, fs_opts)

    with {:ok, wasm} <- JsEngine.build_host(),
         {:ok, sm_pid} <- instantiate(wasm, grant) do

      {:ok,
       %__MODULE__{
         wasm: wasm,
         sm_pid: sm_pid,
         session_id: session_id,
         exec_token: exec_token,
         grant: grant,
         workdir: workdir,
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
    # KEYSTONE: the resident agent loop reaches the host over the SYNCHRONOUS host-import seam
    # (`globalThis.__wbHostCall`, wired into this instance's grant at instantiate) — NOT the wasi:http loopback.
    # The legacy ExecLoopback fetch seam (sentinel/llm URL + token) is still exposed for FALLBACK on a legacy
    # eval-host, but it is now BEST-EFFORT: if the loopback listener isn't running (e.g. unit tests that don't
    # supervise it), boot must NOT crash — the host-import carries the loop. So the seam URLs are nil when the
    # listener is down, and the shims silently prefer __wbHostCall anyway.
    # Always pass a seam MAP when the session carries a token — node_boot_payload's `{seam, _}` branch registers
    # the child_process + fs shims off this (no NEW token mint). The `url` is best-effort: the loopback URL when
    # the listener is up (legacy fetch fallback), else "" — the shims prefer __wbHostCall and never read the url
    # under the host-import, so an empty url is harmless.
    exec_seam =
      if st.exec_token,
        do: %{"url" => safe_sentinel_url() || "", "token" => st.exec_token},
        else: nil

    boot_opts =
      [env: Keyword.get(opts, :env, %{}), argv: Keyword.get(opts, :argv, ["node", "harness"])]
      |> then(fn o -> if exec_seam, do: Keyword.put(o, :exec_seam, exec_seam), else: o end)
      # the session's confined fs root rides the SAME grant; pass it so node_boot_payload registers the SM fs
      # shim (require('node:fs')/'fs/promises') on this resident heap. nil => no fs shim, fs ops would 403.
      |> then(fn o -> if st.workdir, do: Keyword.put(o, :fs, workdir: st.workdir), else: o end)

    case JsEngine.node_boot_payload(boot_opts) do
      {:ok, boot_js, _token} ->
        # 1) install the Node platform (require/process/Buffer/__wbExec) on the live heap;
        # 2) expose the (best-effort) LLM fallback seam the harness reads when no host-import is present;
        # 3) eval the harness JS (installs the resident harness object).
        llm_seam =
          case st.exec_token && safe_llm_url() do
            lurl when is_binary(lurl) -> Jason.encode!(%{"llmUrl" => lurl, "token" => st.exec_token})
            _ -> "null"
          end

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

    case instantiate(st.wasm, st.grant) do
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

  # The whole point: NO `after Process.exit`. Keep the pid alive for the session's lifetime. The session GRANT
  # is bound into the synchronous host-broker import (`wb:jseval/broker.host-call`) HOST-SIDE, so the resident
  # agent loop's llm/fs/exec ops run through that sync import (host performs them in-call) rather than guest
  # wasi:http — which is what lets run() be re-entered across many turns with NO recycle (the keystone fix).
  defp instantiate(wasm, grant) do
    case Wasmex.Components.start_link(%{
           path: wasm,
           wasi: %Wasmex.Wasi.WasiP2Options{allow_http: true},
           imports: JsEngine.host_broker_imports(grant)
         }) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:instantiate_failed, reason}}
    end
  end

  # Mint ONE session token carrying BOTH the exec/LLM grant AND the (optional) confined fs workdir. Either
  # cap alone is enough to mint (an fs-only session is valid: it can fetch the LLM seam + read/write its
  # workdir without spawning). No grant at all => no token. Returns {token | nil, grant | nil, workdir | nil}.
  defp maybe_mint(nil, nil), do: {nil, nil, nil}

  defp maybe_mint(exec_opts, fs_opts) do
    exec_opts = exec_opts || []
    fs_opts = fs_opts || []
    allow = Keyword.get(exec_opts, :allow, false)
    workdir = JsEngine.fs_workdir!(fs_opts)

    # principal: an exec-capable grant MUST carry one (broker rate/concurrency/revoke handle); otherwise prefer
    # whichever opt list supplies it (fs ops are principal-revocable too).
    principal =
      if allow,
        do: require_principal!(true, exec_opts),
        else: Keyword.get(exec_opts, :principal) || Keyword.get(fs_opts, :principal)

    grant = %{
      allow: allow,
      commands: Keyword.get(exec_opts, :commands, :all),
      principal: principal,
      depth: Keyword.get(exec_opts, :depth, 0),
      # SLICE 3: per-(user, provider) creds scope for dock.creds.{get,put}. The harness can only touch the
      # user+provider the host granted — one tenant's grant never reaches another's keychain blob.
      creds_scope: Keyword.get(exec_opts, :creds_scope, nil),
      # headless-JS path: the confined fs root. nil => every /__wb/fs op 403s (no fs reach).
      workdir: workdir
    }

    {ExecLoopback.mint(grant), grant, workdir}
  end

  # An exec-capable session grant (`allow: true`) MUST carry a non-nil principal; refuse to mint one
  # without it (see FIX 1) — it is the broker's only handle for rate-limit / concurrency-cap / revocation.
  defp require_principal!(true, exec_opts) do
    case Keyword.get(exec_opts, :principal) do
      p when is_binary(p) and p != "" ->
        p

      other ->
        raise ArgumentError,
              "exec-capable harness session grant (allow: true) requires a non-nil :principal (tenant/session id) — got #{inspect(other)}."
    end
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, _} = err), do: err
  defp normalize(other), do: {:error, other}

  # Best-effort loopback URLs for the LEGACY fetch fallback seam. nil when the ExecLoopback listener isn't
  # running (unit tests, host-import-only deployments) — boot must not crash, since the resident loop reaches
  # the host over the synchronous host-import, not these URLs.
  defp safe_sentinel_url do
    ExecLoopback.sentinel_url()
  rescue
    _ -> nil
  end

  defp safe_llm_url do
    ExecLoopback.llm_url()
  rescue
    _ -> nil
  end

  defp now, do: System.monotonic_time(:millisecond)
end
