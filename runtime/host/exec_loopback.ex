defmodule Workbooks.ExecLoopback do
  @moduledoc """
  Brokered-EXEC loopback for the StarlingMonkey eval lane (SLICE 1, wb-b9xv.9).

  The SM eval-host (`Workbooks.JsEngine`) has NO host-import surface beyond `wasi:http` — its only seam
  back to the host is a guest `fetch()`. So a Node `child_process` call on this lane cannot reach a wasm
  import the way the QuickJS/JsDock lane does (Javy.Exec → host_exec). Instead it `fetch`es a FIXED
  internal sentinel URL that the vendored WasiHttpView recognizes and pins to THIS loopback listener
  (the SSRF floor is otherwise bypassed for nothing else — see `store.rs` `wb_resolve_pinned`). The
  request bottoms out in the SAME `Workbooks.ExecBroker.exec/4` the JsDock `host_exec` import calls —
  identical security spine (default-deny, registered-only, depth/concurrency/output caps, structural argv).

  Security across the loopback hop: the SM eval lane carries no per-instance grant, and an unauthenticated
  loopback POST must NOT be able to run arbitrary commands. So exec is GATED ON A PER-RUN NONCE TOKEN:
  `JsEngine.run_node/2` mints one (only when the caller passes `:exec`), records `{principal, commands,
  allow}` here, and embeds it in the boot seam; the shim sends it as the `x-wb-exec` header. An absent or
  unknown token => DEFAULT-DENY (the broker is also called with the recorded grant, never a blanket allow).
  Tokens are single-run scoped and revoked when the run ends.
  """
  use Plug.Router
  require Logger

  alias Workbooks.{ExecBroker, HarnessCreds, HarnessProc, OAuthLoopback}

  @grants :wb_exec_loopback_grants
  # streaming children (wb-b9xv.11): handle -> {token, principal, proc_pid}. A spawned HarnessProc is keyed
  # here so /__wb/stream + /__wb/stdin reach it, and so revoke/1 can KILL every in-flight child of a token.
  @procs :wb_exec_loopback_procs
  # per-handle cumulative stdin accounting (wb-b9xv.11 stdin-cap): handle -> {total_bytes, window_start_ms,
  # window_bytes}. Bounds the TOTAL stdin a single streaming child can be fed (not just per-request ~8MB) and
  # rate-limits the firehose; over-cap => reject + kill the child.
  @stdin_meter :wb_exec_loopback_stdin_meter
  # cumulative stdin a single child may be fed over its whole lifetime.
  @stdin_total_cap 16 * 1024 * 1024
  # simple rate limit: at most this many stdin bytes per rolling window.
  @stdin_rate_bytes 4 * 1024 * 1024
  @stdin_rate_window_ms 1_000
  # the fixed internal sentinel host the Rust WasiHttpView pins to this listener (mirrored in store.rs).
  @sentinel_host "wb-exec.internal"

  @doc "The fixed sentinel hostname a guest fetches; pinned to this loopback by the egress override."
  def sentinel_host, do: @sentinel_host

  @doc """
  Base URL a guest `fetch`es to reach the broker, e.g. `http://wb-exec.internal:<port>`. The port is the
  bound loopback port (discovered from the running listener); the host is the recognized sentinel.
  """
  def sentinel_url, do: "http://#{@sentinel_host}:#{port()}/__wb/exec"

  @doc """
  Base URL a guest `fetch`es to reach the LLM-shaped endpoint (SLICE 2, wb-b9xv.10). Same pinned sentinel
  host as exec — one fixed internal route, token-gated, NOT a NetGuard hole. The endpoint is a minimal
  Claude-Messages-shaped completion seam: a real harness turn fetches it to get the model's next move.
  """
  def llm_url, do: "http://#{@sentinel_host}:#{port()}/__wb/llm"

  @doc "The bound loopback port (started in the supervision tree on 127.0.0.1)."
  def port do
    case :persistent_term.get({__MODULE__, :port}, nil) do
      nil -> raise "ExecLoopback not started"
      p -> p
    end
  end

  @doc """
  Child spec: a Bandit listener bound to 127.0.0.1 on an ephemeral port (0 → OS-assigned), recorded in a
  persistent term for `sentinel_url/0` + the Rust pin. 127.0.0.1-only: the sentinel is never reachable
  off-host, and the SSRF bypass in store.rs targets exactly this address.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_listener, []},
      type: :supervisor
    }
  end

  def start_listener do
    # idempotent: if a listener is already bound + recorded (e.g. started by another caller / a prior test
    # setup), reuse it rather than binding a second listener and overwriting the recorded port.
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: do_start_listener()

      _ ->
        do_start_listener()
    end
  end

  defp do_start_listener do
    port = configured_port()

    case Bandit.start_link(plug: __MODULE__, scheme: :http, ip: {127, 0, 0, 1}, port: port) do
      {:ok, pid} ->
        bound = bound_port(pid, port)
        :persistent_term.put({__MODULE__, :port}, bound)
        :persistent_term.put({__MODULE__, :pid}, pid)
        Logger.info("exec-loopback — brokered SM-lane exec listening on 127.0.0.1:#{bound}")
        {:ok, pid}

      other ->
        other
    end
  end

  # FIX 5 (fixed loopback port / token visibility): default to a RANDOM (OS-assigned, port 0) ephemeral port
  # instead of the predictable fixed 8919, so a local process cannot pre-target the loopback by hard-coded
  # port (it would also need the 24-byte single-run token). The bound port is read back from the listener and
  # published to `sentinel_url/0`; the guest receives the full URL (host + bound port) in its grant seam, and
  # the store.rs sentinel pin honors whatever port the guest fetched (it reads `uri.port_u16()`), so nothing
  # needs a hard-coded port. `WB_EXEC_LOOPBACK_PORT` still pins a fixed port when a deployment requires one.
  defp configured_port do
    case System.get_env("WB_EXEC_LOOPBACK_PORT") do
      nil -> 0
      "" -> 0
      s -> String.to_integer(s)
    end
  end

  defp bound_port(_pid, port) when port != 0, do: port

  defp bound_port(pid, 0) do
    # OS-assigned: ask ThousandIsland for the listener info.
    case ThousandIsland.listener_info(pid) do
      {:ok, {_ip, p}} -> p
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # ── grant registry (per-run nonce → grant) ───────────────────────────────────────────────────

  @doc """
  Mint a single-run token for `grant` (`%{principal, commands, allow}`). Returns the opaque token. The
  shim sends it back as `x-wb-exec`; `revoke/1` removes it when the run ends.
  """
  def mint(grant) when is_map(grant) do
    :ok = assert_principal!(grant)
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ets.insert(grants(), {token, grant})
    token
  end

  # FIX 1 (principal-OPTIONAL minting): an EXEC-capable grant (`allow: true`) MUST carry a non-nil principal —
  # that principal is the only handle the broker has for rate-limit / concurrency-cap / revocation. A grant
  # minted with `allow: true` and a nil principal would, via the loopback, call ExecBroker with principal:nil,
  # which is the reserved HOST-INTERNAL (uncapped, unrevocable) path → a granted harness could fork-bomb the
  # host with no cap and no kill-switch. Refuse it at mint time. Creds-only grants (no `:allow`) are unaffected.
  defp assert_principal!(grant) do
    if Map.get(grant, :allow) == true and not valid_principal?(Map.get(grant, :principal)) do
      raise ArgumentError,
            "exec-capable loopback grant (allow: true) requires a non-nil :principal (tenant/session id) — got " <>
              "#{inspect(Map.get(grant, :principal))}. nil-principal is reserved for trusted host-internal callers."
    end

    :ok
  end

  @doc """
  Revoke a minted token (run/session finished OR principal revoked). Removes the grant AND KILLS every
  in-flight streaming child spawned under it — a revoked principal's live streams die mid-flight, not just
  on its next request (the streaming kill-switch the feasibility doc requires).
  """
  def revoke(token) when is_binary(token) do
    kill_procs_for_token(token)
    :ets.delete(grants(), token)
  end

  # ── streaming child registry (handle -> proc) ──────────────────────────────────────────────────

  defp procs, do: Workbooks.BrokerTables.ensure(@procs, [:named_table, :public, :set])

  defp register_proc(token, principal, proc_pid) do
    # The streaming child (HarnessProc) is start_link'd by ExecBroker FROM this Bandit /spawn request process.
    # That request process dies as soon as the spawn RESPONSE is sent — which over the SM guest-fetch lane is
    # BEFORE the first /stream poll arrives (each guest fetch is its own short-lived request process). The link
    # would then kill the child (exit 137, zero chunks) before anything is drained. Unlink it: the child's
    # lifetime is governed by its OWN idle-timeout eviction + explicit kill (revoke / kill_handle / drain-to-
    # exit), NOT by the ephemeral request process that happened to spawn it.
    Process.unlink(proc_pid)
    handle = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    :ets.insert(procs(), {handle, token, principal, proc_pid})
    handle
  end

  defp lookup_proc(handle, token) when is_binary(handle) and is_binary(token) do
    case :ets.lookup(procs(), handle) do
      # a handle is bound to the token that spawned it — another token can never drain/write/kill it.
      [{^handle, ^token, _principal, pid}] -> {:ok, pid}
      _ -> :error
    end
  end

  defp lookup_proc(_, _), do: :error

  defp drop_proc(handle) do
    :ets.delete(stdin_meter(), handle)
    :ets.delete(procs(), handle)
  end

  # ── stdin cumulative cap + rate limit (per handle) ─────────────────────────────────────────────

  defp stdin_meter, do: Workbooks.BrokerTables.ensure(@stdin_meter, [:named_table, :public, :set])

  # Account `data` against the handle's CUMULATIVE byte cap and a rolling-window rate limit. Returns :ok and
  # records the bytes, or {:error, :stdin_cap} when this write would push the total over @stdin_total_cap or
  # the window over @stdin_rate_bytes. A non-binary/empty write is a no-op :ok.
  defp stdin_quota(handle, data) when is_binary(handle) do
    n = byte_size(to_string(data))
    now = System.monotonic_time(:millisecond)

    {total, win_start, win_bytes} =
      case :ets.lookup(stdin_meter(), handle) do
        [{^handle, t, ws, wb}] -> {t, ws, wb}
        _ -> {0, now, 0}
      end

    {win_start, win_bytes} =
      if now - win_start >= @stdin_rate_window_ms, do: {now, 0}, else: {win_start, win_bytes}

    cond do
      total + n > @stdin_total_cap -> {:error, :stdin_cap}
      win_bytes + n > @stdin_rate_bytes -> {:error, :stdin_cap}
      true ->
        :ets.insert(stdin_meter(), {handle, total + n, win_start, win_bytes + n})
        :ok
    end
  end

  defp stdin_quota(_handle, _data), do: :ok

  # kill the child behind a handle (cap breach): same teardown as token/principal revocation for one handle.
  defp kill_handle(handle, token) do
    case lookup_proc(handle, token) do
      {:ok, pid} -> if is_pid(pid) and Process.alive?(pid), do: Workbooks.HarnessProc.kill(pid)
      _ -> :ok
    end

    drop_proc(handle)
  end

  # kill every live child spawned under `token` (token-revocation / session end).
  defp kill_procs_for_token(token) do
    :ets.match_object(procs(), {:_, token, :_, :_})
    |> Enum.each(fn {handle, _t, _p, pid} ->
      if Process.alive?(pid), do: Workbooks.HarnessProc.kill(pid)
      drop_proc(handle)
    end)
  end

  @doc """
  PRINCIPAL-LEVEL streaming kill-switch — kill every in-flight streaming child of `principal`, regardless of
  which token spawned it. Called by `Workbooks.Revocation.revoke/1` so revoking a principal (tenant / serve_id
  / instance) terminates its LIVE streams mid-flight, not just its next request. Idempotent + best-effort: a
  killed pid is dropped from the registry; a principal with no live children is a no-op. The principal here is
  the SAME identity the broker checks via `Revocation.revoked?/1`, so a subsequent drain/spawn is also denied.
  """
  def kill_procs_for_principal(principal) do
    :ets.match_object(procs(), {:_, :_, principal, :_})
    |> Enum.each(fn {handle, _t, _p, pid} ->
      if is_pid(pid) and Process.alive?(pid), do: Workbooks.HarnessProc.kill(pid)
      drop_proc(handle)
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp lookup(token) when is_binary(token) do
    case :ets.lookup(grants(), token) do
      [{^token, grant}] -> {:ok, grant}
      _ -> :error
    end
  end

  defp lookup(_), do: :error

  # FIX 1 (defense-in-depth at the loopback route): an exec-capable grant reaching the broker MUST carry a
  # non-nil principal so the broker's rate/concurrency/revocation guards engage. `mint/1` already refuses to
  # create such a grant, but the route NEVER calls ExecBroker with a nil principal from the loopback — a
  # principal-less exec/llm grant is DENIED here (403). nil-principal stays reserved for trusted HOST-INTERNAL
  # callers (e.g. JsDock direct ExecBroker.exec calls), which never traverse this loopback.
  defp principal_gate(grant) do
    cond do
      Map.get(grant, :allow) != true -> :ok
      valid_principal?(Map.get(grant, :principal)) -> :ok
      true -> {:error, :no_principal}
    end
  end

  defp valid_principal?(p), do: is_binary(p) and p != ""

  # FIX 5 (token visibility): the grant table stays `:public` because mint/revoke run in the JsEngine /
  # HarnessSession processes while lookup runs in Bandit handler processes — none of them is the table's
  # owner (BrokerTables), so `:protected` (owner-only writes) would break mint/revoke from those callers.
  # The residual exposure is mitigated structurally instead: tokens are 24 bytes of CSPRNG entropy, are
  # single-run scoped (revoked when the run/session ends), and now sit behind a RANDOM loopback port (FIX 5),
  # and every exec-capable grant is principal-governed (FIX 1).
  defp grants, do: Workbooks.BrokerTables.ensure(@grants, [:named_table, :public, :set])

  # ── route ────────────────────────────────────────────────────────────────────────────────────

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
  plug(:dispatch)

  # POST /__wb/exec  body {name, argv, stdin}  header x-wb-exec: <token>
  # Bottoms out in ExecBroker.exec/4 with the token's recorded grant — DEFAULT-DENY on unknown token.
  post "/__wb/exec" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    name = conn.body_params["name"]
    argv = conn.body_params["argv"] || []
    stdin = conn.body_params["stdin"] || ""

    with {:ok, grant} <- lookup(token),
         true <- is_binary(name) and is_list(argv),
         :ok <- principal_gate(grant) do
      case ExecBroker.exec(name, Enum.map(argv, &to_string/1), to_string(stdin),
             allow: Map.get(grant, :allow, false),
             commands: Map.get(grant, :commands, :all),
             principal: Map.get(grant, :principal),
             depth: Map.get(grant, :depth, 0) + 1
           ) do
        {:ok, out} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, out)

        {:error, reason} ->
          # 403 so the shim surfaces "denied" rather than a transport error.
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(403, "exec denied: #{inspect(reason)}")
      end
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "exec denied: no/invalid grant token")
    end
  end

  # ── STREAMING child_process (wb-b9xv.11) ───────────────────────────────────────────────────────
  #
  # A LONG-LIVED child held across tool round-trips, with INCREMENTAL stdout, a writable stdin, and exit
  # propagation. Same token gate + principal gate + broker spine as /__wb/exec; the only difference is the
  # work is a streaming HarnessProc instead of a buffered one-shot. Three routes:
  #   POST /__wb/spawn        body {name, argv}  -> {handle}     (gated; starts the child)
  #   POST /__wb/stream/<h>                      -> one chunk    (long-poll; x-wb-exit header on the last)
  #   POST /__wb/stdin/<h>    body {data}        -> {ok}         (writes the child's stdin)
  # A handle is bound to its spawning token; another token can't touch it. revoke(token) kills the child.

  # POST /__wb/spawn  body {name, argv}  header x-wb-exec: <token>
  post "/__wb/spawn" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    name = conn.body_params["name"]
    argv = conn.body_params["argv"] || []

    with {:ok, grant} <- lookup(token),
         true <- is_binary(name) and is_list(argv),
         :ok <- principal_gate(grant) do
      case ExecBroker.spawn_stream(name, Enum.map(argv, &to_string/1),
             allow: Map.get(grant, :allow, false),
             commands: Map.get(grant, :commands, :all),
             principal: Map.get(grant, :principal),
             depth: Map.get(grant, :depth, 0) + 1
           ) do
        {:ok, proc} ->
          handle = register_proc(token, Map.get(grant, :principal), proc)
          send_json(conn, 200, %{"handle" => handle})

        {:error, reason} ->
          send_resp(conn, 403, "spawn denied: #{inspect(reason)}")
      end
    else
      _ -> send_resp(conn, 403, "spawn denied: no/invalid grant token")
    end
  end

  # POST /__wb/stream/<handle>  header x-wb-exec: <token>
  # Long-poll ONE incremental chunk. Body = the bytes produced since the last drain (may be empty if the
  # child hasn't flushed yet — the poller loops). On the child's exit the response carries x-wb-exit: <code>
  # and x-wb-done: 1 so the consumer's spawn() can emit 'end' + 'exit'.
  post "/__wb/stream/:handle" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()

    with {:ok, grant} <- lookup(token),
         false <- principal_revoked?(grant),
         {:ok, pid} <- lookup_proc(conn.params["handle"], token) do
      case safe_drain(pid) do
        {:ok, chunk, :open} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("x-wb-done", "0")
          |> send_resp(200, chunk)

        {:ok, chunk, {:exited, code}} ->
          drop_proc(conn.params["handle"])

          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("x-wb-exit", to_string(code || 0))
          |> put_resp_header("x-wb-done", "1")
          |> send_resp(200, chunk)

        :dead ->
          drop_proc(conn.params["handle"])

          conn
          |> put_resp_header("x-wb-exit", "137")
          |> put_resp_header("x-wb-done", "1")
          |> send_resp(200, "")
      end
    else
      _ -> send_resp(conn, 403, "stream denied: no/invalid grant or handle")
    end
  end

  # POST /__wb/stdin/<handle>  body {data}  header x-wb-exec: <token>
  post "/__wb/stdin/:handle" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    data = conn.body_params["data"] || ""

    with {:ok, grant} <- lookup(token),
         false <- principal_revoked?(grant),
         {:ok, pid} <- lookup_proc(conn.params["handle"], token),
         :ok <- stdin_quota(conn.params["handle"], data),
         :ok <- HarnessProc.write_stdin(pid, to_string(data)) do
      send_json(conn, 200, %{"ok" => true})
    else
      {:error, :stdin_cap} ->
        # over the per-handle CUMULATIVE stdin cap (or rate limit): reject AND kill the child — a guest can't
        # feed an unbounded stdin firehose past the cap, and the offending child is torn down on breach.
        kill_handle(conn.params["handle"], token)
        send_resp(conn, 429, "stdin denied: cumulative cap or rate limit exceeded")

      _ ->
        send_resp(conn, 403, "stdin denied: no/invalid grant, handle, or closed child")
    end
  end

  # principal-level kill-switch at the route: a revoked principal's grant is refused EVEN IF the token grant
  # still exists — Revocation.revoke/1 also kills the live child (kill_procs_for_principal), so this is the
  # belt to that suspenders (the next drain/stdin gets a clean 403 rather than racing the kill).
  defp principal_revoked?(grant) do
    case Map.get(grant, :principal) do
      p when is_binary(p) and p != "" -> Workbooks.Revocation.revoked?(p)
      _ -> false
    end
  end

  # A killed/exited HarnessProc may already be down; treat a dead pid as terminal rather than crashing the
  # route (revocation races a drain).
  defp safe_drain(pid) do
    if Process.alive?(pid), do: HarnessProc.drain(pid), else: :dead
  rescue
    _ -> :dead
  catch
    :exit, _ -> :dead
  end

  # ── BROKERED FS (headless-JS path) ─────────────────────────────────────────────────────────────
  #
  # The SM eval lane has NO host-import FS (the Javy `fs` shim is dead here). A Node `fs`/`fs/promises`
  # call on this lane reaches the host the only way SM can — a guest `fetch()` to the SAME pinned
  # `wb-exec.internal` sentinel — over ONE verb-dispatched route. Token-gated (unknown token => deny) AND
  # CONFINED to the grant's `:workdir`: every path is resolved INSIDE the workdir and any escape (`..`,
  # absolute, symlink target outside) is refused with 403. There is NO arbitrary host FS reach — a grant
  # with no `:workdir` gets a clean 403 for every fs op. Verbs: read/write/append/stat/readdir/mkdir/
  # exists/unlink. Bytes cross the JSON hop base64-encoded so binary round-trips.
  #
  # POST /__wb/fs  body {op, path, data?, recursive?}  header x-wb-exec: <token>
  post "/__wb/fs" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    fsop = conn.body_params["op"]
    raw_path = conn.body_params["path"]

    with {:ok, grant} <- lookup(token),
         false <- principal_revoked?(grant),
         {:ok, workdir} <- fs_workdir(grant),
         {:ok, abs} <- confine(workdir, raw_path) do
      fs_dispatch(conn, fsop, abs, conn.body_params)
    else
      {:error, :no_workdir} ->
        send_json(conn, 403, %{"error" => "fs denied: no workdir granted on this run"})

      {:error, :escape} ->
        send_json(conn, 403, %{"error" => "fs denied: path escapes the workdir"})

      _ ->
        send_json(conn, 403, %{"error" => "fs denied: no/invalid grant token"})
    end
  end

  # The confined root for fs ops — the grant's :workdir (an absolute host dir created by the caller). Absent
  # => no fs access at all (every op 403s). The host NEVER honors a path outside this root.
  defp fs_workdir(grant) do
    case Map.get(grant, :workdir) do
      d when is_binary(d) and d != "" -> {:ok, Path.expand(d)}
      _ -> {:error, :no_workdir}
    end
  end

  # Resolve `raw` INSIDE `workdir` and refuse any escape. A path is treated as workdir-relative (a leading
  # "/" is stripped so an "absolute" guest path still lands in the workdir); `..` segments that would climb
  # above the workdir are rejected. The final real path (symlinks resolved on the existing prefix) must still
  # be a prefix-descendant of the workdir — so a symlink inside the workdir can't be used to read outside it.
  defp confine(workdir, raw) when is_binary(raw) and raw != "" do
    rel = String.trim_leading(raw, "/")

    case Path.safe_relative(rel) do
      {:ok, safe} ->
        abs = Path.expand(safe, workdir)
        # belt: the expanded path must be the workdir itself or strictly inside it.
        if abs == workdir or String.starts_with?(abs, workdir <> "/"),
          do: {:ok, no_symlink_escape(workdir, abs)},
          else: {:error, :escape}

      :error ->
        {:error, :escape}
    end
  end

  defp confine(_workdir, _raw), do: {:error, :escape}

  # Canonicalize the nearest EXISTING ancestor of `abs` (resolving every symlink component) and verify it is
  # still inside the workdir — so a symlink planted inside the workdir can't be used to read/write OUTSIDE it.
  # A fresh file to be created has no real path yet, so we canonicalize its nearest existing parent. Returns
  # the (lexically-confined) `abs` when safe, or `:escape`.
  defp no_symlink_escape(workdir, abs) do
    probe = if File.exists?(abs), do: abs, else: Path.dirname(abs)
    canon = realpath(probe)

    if canon == workdir or String.starts_with?(canon, workdir <> "/"),
      do: abs,
      else: :escape
  end

  # Best-effort realpath: walk down from root resolving any symlink component, capped to avoid link cycles.
  # Falls back to the lexical path on any read error (a non-existent leaf simply has no link to resolve).
  defp realpath(path), do: realpath(Path.expand(path), 64)

  defp realpath(path, 0), do: path

  defp realpath(path, fuel) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        t = to_string(target)
        resolved = if String.starts_with?(t, "/"), do: t, else: Path.expand(t, Path.dirname(path))
        realpath(resolved, fuel - 1)

      _ ->
        path
    end
  end

  # Execute one fs verb against the (already-confined) absolute path. Errors map to HTTP the shim understands:
  # 404 => ENOENT, 403 => EACCES/denied, 5xx => EIO. Bytes are base64 on the wire.
  defp fs_dispatch(conn, "read", abs, _params) do
    case File.read(abs) do
      {:ok, bin} -> send_json(conn, 200, %{"data" => Base.encode64(bin)})
      {:error, :enoent} -> send_json(conn, 404, %{"error" => "ENOENT"})
      {:error, :eisdir} -> send_json(conn, 403, %{"error" => "EISDIR"})
      {:error, reason} -> send_json(conn, 500, %{"error" => to_string(reason)})
    end
  end

  defp fs_dispatch(conn, "write", abs, params) do
    with {:ok, bytes} <- fs_decode(params["data"]),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, bytes) do
      send_json(conn, 200, %{"ok" => true})
    else
      _ -> send_json(conn, 500, %{"error" => "EIO"})
    end
  end

  defp fs_dispatch(conn, "append", abs, params) do
    with {:ok, bytes} <- fs_decode(params["data"]),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, bytes, [:append]) do
      send_json(conn, 200, %{"ok" => true})
    else
      _ -> send_json(conn, 500, %{"error" => "EIO"})
    end
  end

  defp fs_dispatch(conn, "exists", abs, _params) do
    send_json(conn, 200, %{"exists" => File.exists?(abs)})
  end

  defp fs_dispatch(conn, "stat", abs, _params) do
    case File.stat(abs, time: :posix) do
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
        send_json(conn, 200, %{
          "size" => size,
          "is_dir" => type == :directory,
          "mtime_ms" => (mtime || 0) * 1000
        })

      {:error, :enoent} -> send_json(conn, 404, %{"error" => "ENOENT"})
      {:error, reason} -> send_json(conn, 500, %{"error" => to_string(reason)})
    end
  end

  defp fs_dispatch(conn, "readdir", abs, _params) do
    case File.ls(abs) do
      {:ok, entries} -> send_json(conn, 200, %{"entries" => entries})
      {:error, :enoent} -> send_json(conn, 404, %{"error" => "ENOENT"})
      {:error, reason} -> send_json(conn, 500, %{"error" => to_string(reason)})
    end
  end

  defp fs_dispatch(conn, "mkdir", abs, params) do
    res = if params["recursive"], do: File.mkdir_p(abs), else: File.mkdir(abs)

    case res do
      :ok -> send_json(conn, 200, %{"ok" => true})
      {:error, :eexist} -> send_json(conn, 200, %{"ok" => true})
      {:error, reason} -> send_json(conn, 500, %{"error" => to_string(reason)})
    end
  end

  defp fs_dispatch(conn, "unlink", abs, params) do
    res = if params["recursive"], do: File.rm_rf(abs), else: File.rm(abs)

    case res do
      :ok -> send_json(conn, 200, %{"ok" => true})
      {:ok, _} -> send_json(conn, 200, %{"ok" => true})
      {:error, :enoent} -> send_json(conn, 404, %{"error" => "ENOENT"})
      {:error, reason, _} -> send_json(conn, 500, %{"error" => to_string(reason)})
      {:error, reason} -> send_json(conn, 500, %{"error" => to_string(reason)})
    end
  end

  defp fs_dispatch(conn, _unknown, _abs, _params) do
    send_json(conn, 400, %{"error" => "unknown fs op"})
  end

  defp fs_decode(nil), do: {:ok, ""}
  defp fs_decode(b64) when is_binary(b64), do: Base.decode64(b64)
  defp fs_decode(_), do: :error

  # POST /__wb/llm  body {messages, tools}  header x-wb-exec: <token>
  # An LLM-shaped completion seam (SLICE 2, wb-b9xv.10) for a real headless harness turn. Token-gated like
  # exec (no token => default-deny). DETERMINISTIC mock of the Claude Messages protocol so the THESIS test
  # is hermetic, while the SEAM is fully real (real fetch → HTTP → request/response JSON the harness parses):
  #   - turn 1 (no tool_result yet): return a `tool_use` block (the model decides to call a tool), and
  #   - turn 2 (a tool_result is present): return the final `text` answer that quotes the tool output.
  # This drives the harness's multi-round tool loop end-to-end on the live engine. A real provider can be
  # swapped behind this exact route later (the harness JS is provider-agnostic — it reads stop_reason +
  # content blocks). The route is intentionally minimal; it is NOT the production agent loop.
  post "/__wb/llm" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    messages = conn.body_params["messages"] || []

    with {:ok, grant} <- lookup(token),
         :ok <- principal_gate(grant) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(llm_complete(messages)))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "llm denied: no/invalid grant token")
    end
  end

  # ── SLICE 3 (wb-b9xv.7) — the three subscription-auth Dock ops, same pinned sentinel + token gate ─────
  #
  # dock.creds.{get,put} + dock.oauth.loopback. The harness reaches them by `fetch`ing the SAME
  # `wb-exec.internal` sentinel (already pinned to this loopback in store.rs — NO new egress hole, no
  # store.rs change), token-gated like exec/llm (unknown/absent token => default-deny). The per-(user,
  # provider) creds scope is the GRANT's `:creds_scope` — the harness can only touch the user+provider the
  # host granted (BYO + no-pool: one tenant's grant can never read another's blob).

  # POST /__wb/creds/get  body {provider}  header x-wb-exec: <token>
  # -> 200 {"found":true,"blob":"<opaque>"} | 200 {"found":false}. The blob is the harness's own opaque
  # creds bundle (e.g. ~/.claude/.credentials.json contents). The user is the GRANT's scope, never the body
  # (the harness cannot read another user's creds by asking for them).
  post "/__wb/creds/get" do
    with {:ok, grant} <- lookup(get_req_header(conn, "x-wb-exec") |> List.first()),
         {:ok, user} <- creds_user(grant),
         {:ok, provider} <- creds_provider(grant, conn.body_params["provider"]) do
      case HarnessCreds.get(user, provider) do
        {:ok, blob} ->
          send_json(conn, 200, %{"found" => true, "blob" => blob})

        {:error, :not_found} ->
          send_json(conn, 200, %{"found" => false})
      end
    else
      err -> send_resp(conn, 403, "creds denied: #{inspect(err)}")
    end
  end

  # POST /__wb/creds/put  body {provider, blob}  header x-wb-exec: <token>
  # -> 200 {"ok":true}. Stores the opaque blob for the GRANT's user + the (scoped) provider. We never parse
  # the blob; it is the user's subscription token and goes only to the user's keychain (HarnessCreds).
  post "/__wb/creds/put" do
    with {:ok, grant} <- lookup(get_req_header(conn, "x-wb-exec") |> List.first()),
         {:ok, user} <- creds_user(grant),
         {:ok, provider} <- creds_provider(grant, conn.body_params["provider"]),
         blob when is_binary(blob) <- conn.body_params["blob"],
         :ok <- HarnessCreds.put(user, provider, blob) do
      send_json(conn, 200, %{"ok" => true})
    else
      err -> send_resp(conn, 403, "creds put denied: #{inspect(err)}")
    end
  end

  # POST /__wb/oauth/loopback  body {authorize_base, code_challenge, client_id?, scope?, state?}
  #   header x-wb-exec: <token>
  # -> 200 {"code":"…","redirect_uri":"…"}. Opens the user's browser to the authorize URL (their session,
  # their IP), captures the loopback `?code=`, returns it. PKCE-less: the harness supplies the challenge and
  # keeps the verifier. Desktop-only (loopback + local browser); returns 503 with a clear reason otherwise.
  post "/__wb/oauth/loopback" do
    with {:ok, _grant} <- lookup(get_req_header(conn, "x-wb-exec") |> List.first()) do
      case OAuthLoopback.start(conn.body_params) do
        {:ok, %{code: code, redirect_uri: redirect_uri}} ->
          send_json(conn, 200, %{"code" => code, "redirect_uri" => redirect_uri})

        {:error, :desktop_only} ->
          send_resp(conn, 503, "oauth.loopback unavailable: desktop-only (no local browser/loopback here)")

        {:error, reason} ->
          send_resp(conn, 502, "oauth.loopback failed: #{inspect(reason)}")
      end
    else
      _ -> send_resp(conn, 403, "oauth denied: no/invalid grant token")
    end
  end

  # The user is fixed by the GRANT's creds_scope — NEVER the request body. Absent scope => no creds access.
  defp creds_user(grant) do
    case get_in(grant, [:creds_scope, :user]) || (is_map(grant[:creds_scope]) && grant.creds_scope["user"]) do
      u when is_binary(u) and u != "" -> {:ok, u}
      _ -> {:error, :no_creds_scope}
    end
  end

  # The provider must be on the grant's allowed providers. A single-provider scope ignores the body provider
  # (uses the granted one); a multi-provider scope requires the requested provider to be on the list.
  defp creds_provider(grant, requested) do
    scope = grant[:creds_scope] || %{}
    granted = scope[:provider] || scope["provider"]
    allowed = scope[:providers] || scope["providers"]

    cond do
      is_binary(granted) and granted != "" -> {:ok, granted}
      is_list(allowed) and is_binary(requested) and requested in allowed -> {:ok, requested}
      true -> {:error, :provider_not_in_scope}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Has the conversation already carried a tool_result back? (a user-role message containing a tool_result
  # block). If not, ask for a tool call; if yes, emit the final answer quoting the tool's stdout.
  defp llm_complete(messages) do
    tool_result = find_tool_result(messages)

    if tool_result do
      answer = "The repository has #{String.trim(tool_result)} matching lines."

      %{
        "id" => "msg_wb_llm_final",
        "type" => "message",
        "role" => "assistant",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => answer}]
      }
    else
      %{
        "id" => "msg_wb_llm_tool",
        "type" => "message",
        "role" => "assistant",
        "stop_reason" => "tool_use",
        "content" => [
          %{"type" => "text", "text" => "I'll count the matching lines."},
          %{
            "type" => "tool_use",
            "id" => "toolu_wb_1",
            "name" => "run_command",
            "input" => %{"command" => "grep", "args" => ["needle"], "stdin" => "needle\nhay\nneedle\nstraw\nneedle\n"}
          }
        ]
      }
    end
  end

  # Find a tool_result block anywhere in the message history (a user-role message whose content array
  # carries a {"type":"tool_result", ...}); return its text content, or nil.
  defp find_tool_result(messages) do
    Enum.find_value(messages, fn m ->
      content = (is_map(m) && m["content"]) || nil

      if is_list(content) do
        Enum.find_value(content, fn b ->
          if is_map(b) and b["type"] == "tool_result" do
            case b["content"] do
              t when is_binary(t) -> t
              [%{"text" => t} | _] -> t
              _ -> nil
            end
          end
        end)
      end
    end)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
