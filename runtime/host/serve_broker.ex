defmodule Workbooks.ServeBroker do
  @moduledoc """
  wb-broker INBOUND server-flip (Stone 5 / app-host) — the host listens, a GUEST handles. The host owns the
  socket (the privileged op); per request it hands the guest the bytes and takes back the guest's response.
  The guest never touches a socket — it stays sandboxed; only its handler logic runs.

  Flow (no host->guest memory writes; everything rides the proven import + an ETS channel):
    1. host: `dispatch(serve_id, pid, request)` stashes the request (ETS) and calls the guest's `handle`.
    2. guest handle(): `host_request_get(buf, cap)` -> host writes the request into the guest's buffer
       (ctx.memory); guest processes; `host_response_set(ptr, len)` -> host reads the response back.
    3. host: returns the captured response.
  A persistent guest instance is re-entered per request (the handler is long-lived, like a server).
  Security: response size-capped; the request channel is per serve_id (one guest never sees another's).
  """
  @table :wb_serve

  @doc "Env imports a serving guest needs. `serve_id` scopes its request/response channel."
  def imports(serve_id, opts \\ []) do
    max_resp = Keyword.get(opts, :max_response, 4 * 1024 * 1024)

    %{
      # host_request_get(out_ptr, out_cap) -> i32 : write the current request into the guest buffer, return
      # its length (request bytes; truncated to cap).
      "host_request_get" =>
        {:fn, [:i32, :i32], [:i32],
         fn ctx, ptr, cap ->
           req = lookup({serve_id, :req}) || ""
           n = min(byte_size(req), cap)
           :ok = Wasmex.Memory.write_binary(ctx.caller, ctx.memory, ptr, binary_part(req, 0, n))
           n
         end},
      # host_response_set(ptr, len) -> i32 : capture the guest's response (size-capped). Returns 0.
      "host_response_set" =>
        {:fn, [:i32, :i32], [:i32],
         fn ctx, ptr, len ->
           len = min(len, max_resp)
           resp = Wasmex.Memory.read_binary(ctx.caller, ctx.memory, ptr, len)
           put({serve_id, :resp}, resp)
           0
         end}
    }
  end

  @doc """
  Marshal an HTTP request into the bytes the guest handler sees, HTTP-message-shaped:

      METHOD PATH\\n  Header: value\\n  ...\\n  \\n  <body>

  request line, forwarded headers, a blank line, then the (binary-safe) body.
  """
  def encode_http_request(method, path, headers, body) when is_list(headers) and is_binary(body) do
    hdr = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\n" end)
    method <> " " <> path <> "\n" <> hdr <> "\n" <> body
  end

  @doc """
  Decode the guest's response bytes (same shape: `STATUS\\nHeader: v\\n\\n<body>`) into
  `{status, [{header, value}], body}`. A guest that returns plain bytes (no `\\n\\n`) is treated as a
  200 with that body — so a minimal handler still works.
  """
  def decode_http_response(bytes) when is_binary(bytes) do
    case :binary.split(bytes, "\n\n") do
      [head, body] -> parse_head(head, body)
      [body] -> {200, [], body}
    end
  end

  defp parse_head(head, body) do
    [status_line | hlines] = String.split(head, "\n")

    status =
      case Integer.parse(String.trim(status_line)) do
        {n, _} when n in 100..599 -> n
        _ -> 200
      end

    headers =
      Enum.flat_map(hlines, fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> [{String.downcase(String.trim(k)), String.trim(v)}]
          _ -> []
        end
      end)

    {status, headers, body}
  end

  @doc """
  Dispatch one request to the guest's `handle` export; returns {:ok, response} | {:error, reason}.
  opts: `:timeout` (ms), `:rate` `{max, window_ms}` (per-serve_id inbound flood floor — checked BEFORE the
  guest runs, so a flood is rejected without spending guest CPU). Mirrors the outbound brokers' cadence.
  """
  def dispatch(serve_id, pid, request, opts \\ []) when is_binary(request) do
    rate = Keyword.get(opts, :rate)
    timeout = Keyword.get(opts, :timeout, 10_000)

    cond do
      Workbooks.Revocation.revoked?(serve_id) ->
        Workbooks.BrokerAudit.record(:serve, :deny, :revoked)
        {:error, :revoked}

      rate && rate_denied?(serve_id, rate) ->
        Workbooks.BrokerAudit.record(:serve, :deny, :rate_limited)
        {:error, :rate_limited}

      true ->
        do_dispatch(serve_id, pid, request, timeout)
    end
  end

  defp rate_denied?(serve_id, {max, window}),
    do: Workbooks.RateLimiter.check(serve_id, max, window) == {:error, :rate_limited}

  defp do_dispatch(serve_id, pid, request, timeout) do
    # The {serve_id,:req}/{serve_id,:resp} channel + the single persistent guest mean concurrent requests to
    # ONE serve_id MUST run one-at-a-time — otherwise request A's call could read request B's just-written
    # bytes. Serialize the whole put->call->lookup per serve_id (the guest is single-threaded anyway).
    with_lock(serve_id, fn ->
      put({serve_id, :req}, request)
      delete({serve_id, :resp})

      case Wasmex.call_function(pid, "handle", [], timeout) do
        {:ok, _} -> {:ok, lookup({serve_id, :resp}) || ""}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Atomic per-serve_id critical section via ETS insert_new (test-and-set). try/after releases the lock even
  # if the guest call raises; the 1ms backoff is bounded in practice by the inbound rate limit.
  defp with_lock(serve_id, fun) do
    key = {serve_id, :lock}

    if :ets.insert_new(table(), {key, true}) do
      try do
        fun.()
      after
        :ets.delete(table(), key)
      end
    else
      Process.sleep(1)
      with_lock(serve_id, fun)
    end
  end

  # --- lazy public ETS channel (shared across the caller + the wasmex worker process) ---
  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

        @table

      _ ->
        @table
    end
  end

  defp put(k, v), do: :ets.insert(table(), {k, v})
  defp delete(k), do: :ets.delete(table(), k)

  defp lookup(k) do
    case :ets.lookup(table(), k) do
      [{_, v}] -> v
      _ -> nil
    end
  end
end

defmodule Workbooks.ServeBroker.Plug do
  @moduledoc """
  Bandit/Plug adapter for the inbound serve-flip: the HOST owns the listening socket; each HTTP request is
  marshaled to bytes, handed to the GUEST's `handle`, and the guest's response bytes become the HTTP body.
  The guest never touches the socket. opts: `:serve_id`, `:pid` (a persistent serving guest instance).
  """
  @behaviour Plug
  import Plug.Conn
  alias Workbooks.ServeBroker

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    serve_id = Keyword.fetch!(opts, :serve_id)
    pid = Keyword.fetch!(opts, :pid)
    max_req = Keyword.get(opts, :max_request_bytes, 4 * 1024 * 1024)
    rate = Keyword.get(opts, :rate)

    # DoS floor (huge-body): cap the host-side read; a request larger than max_req is rejected cleanly (413)
    # instead of crashing the read_body match or buffering unbounded host memory.
    case read_body(conn, length: max_req) do
      {:ok, body, conn} ->
        req = ServeBroker.encode_http_request(conn.method, conn.request_path, conn.req_headers, body)

        case ServeBroker.dispatch(serve_id, pid, req, rate: rate) do
          {:ok, resp} ->
            {status, headers, out} = ServeBroker.decode_http_response(resp)
            conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
            send_resp(conn, status, out)

          {:error, :rate_limited} ->
            send_resp(conn, 429, "rate limited")

          {:error, _} ->
            send_resp(conn, 502, "guest handler error")
        end

      {:more, _partial, conn} ->
        send_resp(conn, 413, "request too large")
    end
  end
end

defmodule Workbooks.ServeBroker.ComponentPlug do
  @moduledoc """
  Bandit/Plug adapter for the STANDARD-component inbound seam (the app-host platform). The HOST owns the
  listening socket; each HTTP request is driven straight into a persistent wasi:http SERVER COMPONENT via
  `Wasmex.Components.serve_http/6`, and the component's `{status, headers, body}` becomes the HTTP response.
  The guest never touches the socket — only its `wasi:http/incoming-handler` runs, and any OUTBOUND it makes
  is still SSRF-brokered. opts: `:pid` (a persistent wasi:http Components instance), `:max_request_bytes`.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    max_req = Keyword.get(opts, :max_request_bytes, 4 * 1024 * 1024)

    cond do
      # MID-FLIGHT REVOCATION (opt-in `:serve_id`) — a hosted app can be killed without killing the server;
      # once its serve_id is revoked, every subsequent request is refused (503).
      revoked?(Keyword.get(opts, :serve_id)) ->
        send_resp(conn, 503, "service revoked")

      # INBOUND DoS floor (opt-in `:rate` = {max, window_ms}) — PER-CLIENT (by remote IP) so a flood from one
      # client can't starve others or exhaust the host with unbounded request handling / instantiation.
      rate_limited?(conn, Keyword.get(opts, :rate)) ->
        send_resp(conn, 429, "rate limited")

      true ->
        # DoS floor: cap the host-side read (clean 413 instead of a crash / unbounded buffering)
        case read_body(conn, length: max_req) do
          {:ok, body, conn} ->
            if Keyword.get(opts, :stream) do
              # STREAMING (`:stream` + `:component` + `:engine`): the response body is forwarded to the client
              # via chunked transfer AS the guest produces it — large downloads / SSE without host buffering.
              dispatch_stream(opts, conn, body)
            else
              case dispatch(opts, conn, body) do
                {status, headers, resp_body} when is_integer(status) ->
                  conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
                  send_resp(conn, status, resp_body)

                {:error, _} ->
                  send_resp(conn, 502, "wasi:http component error")
              end
            end

          {:more, _partial, conn} ->
            send_resp(conn, 413, "request too large")
        end
    end
  end

  # STREAMING dispatch: instantiate a fresh instance, spawn the (blocking, DirtyCpu) stream NIF in a separate
  # process so THIS Plug process stays free to receive {ref, :stream_*} messages and forward each chunk via
  # chunked transfer the instant it arrives. Large downloads / SSE flow without the host buffering the body.
  defp dispatch_stream(opts, conn, body) do
    component = Keyword.fetch!(opts, :component)
    engine = Keyword.fetch!(opts, :engine)
    wasi = Keyword.get(opts, :wasi_options, %Wasmex.Wasi.WasiP2Options{allow_http: true})
    # compute-DoS guard (epoch engine + :epoch_deadline) — a spinning guest is trapped; 0 = no deadline.
    epoch = Keyword.get(opts, :epoch_deadline, 0)

    with {:ok, store} <- Wasmex.Components.Store.new_wasi(wasi, nil, engine),
         {:ok, inst} <- Wasmex.Components.Instance.new(store, component, %{}) do
      ref = make_ref()
      parent = self()

      pid =
        spawn(fn ->
          try do
            Wasmex.Components.Instance.serve_http_stream(
              inst,
              conn.method,
              conn.request_path,
              conn.req_headers,
              body,
              parent,
              ref,
              epoch
            )
          rescue
            _ -> send(parent, {ref, :stream_error, :handler_error})
          catch
            _, _ -> send(parent, {ref, :stream_error, :handler_error})
          end
        end)

      # MONITOR the handler: if it finishes/crashes WITHOUT delivering a start frame (e.g. a compute-DoS guest
      # trapped by the epoch deadline yields a response the host can't forward), we get a :DOWN and fail fast
      # with 502 instead of waiting out the receive backstop.
      mon = Process.monitor(pid)
      receive_stream_start(conn, ref, mon, pid)
    else
      _ -> send_resp(conn, 502, "wasi:http component error")
    end
  end

  defp receive_stream_start(conn, ref, mon, pid) do
    receive do
      {^ref, :stream_start, status, headers} ->
        Process.demonitor(mon, [:flush])
        conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
        conn = send_chunked(conn, status)
        stream_loop(conn, ref)

      # the handler raised (caught in the spawn) — fail fast rather than waiting out the receive timeout.
      {^ref, :stream_error, _reason} ->
        Process.demonitor(mon, [:flush])
        send_resp(conn, 500, "wasi:http component error")

      # the handler finished/crashed without delivering a start frame (e.g. a trapped compute-DoS guest whose
      # default response the host can't forward) — fail fast with 502.
      {:DOWN, ^mon, :process, ^pid, _reason} ->
        send_resp(conn, 502, "wasi:http component produced no response")
    after
      # final backstop (e.g. a handler that neither delivers a start nor exits within the window).
      15_000 ->
        Process.demonitor(mon, [:flush])
        send_resp(conn, 504, "stream start timeout")
    end
  end

  defp stream_loop(conn, ref) do
    receive do
      {^ref, :stream_data, data} ->
        case chunk(conn, data) do
          {:ok, conn} -> stream_loop(conn, ref)
          # client disconnected mid-stream — stop forwarding, the response is already committed
          {:error, _} -> conn
        end

      {^ref, :stream_done} ->
        conn
    after
      15_000 -> conn
    end
  end

  defp revoked?(nil), do: false
  defp revoked?(serve_id), do: Workbooks.Revocation.revoked?(serve_id)

  defp rate_limited?(_conn, nil), do: false

  defp rate_limited?(conn, {max, window}) do
    key = "apphost:" <> (conn.remote_ip |> :inet.ntoa() |> to_string())
    Workbooks.RateLimiter.check(key, max, window) == {:error, :rate_limited}
  end

  # Two modes:
  #  * `:component` (+ `:engine`) — FRESH-PER-REQUEST: instantiate a fresh store+instance from the
  #    pre-compiled component for each request. Correct wasi:http serve model — per-request ISOLATION (no
  #    state leak) + natural concurrency (each request its own instance, no GenServer serialization).
  #  * `:pids` / `:pid` — REUSED instances (a pool or single). Cheaper, fine for stateless handlers.
  defp dispatch(opts, conn, body) do
    case Keyword.get(opts, :component) do
      nil ->
        pid =
          case Keyword.get(opts, :pids) do
            [_ | _] = pids -> Enum.random(pids)
            _ -> Keyword.fetch!(opts, :pid)
          end

        Wasmex.Components.serve_http(pid, conn.method, conn.request_path, conn.req_headers, body)

      component ->
        engine = Keyword.fetch!(opts, :engine)
        wasi = Keyword.get(opts, :wasi_options, %Wasmex.Wasi.WasiP2Options{allow_http: true})
        # compute-DoS guard: with an epoch engine + :epoch_deadline, a guest spinning in handle() is trapped
        # (see Instance.serve_http). 0 (default) = no deadline (caller didn't opt into an epoch engine).
        epoch = Keyword.get(opts, :epoch_deadline, 0)

        try do
          {:ok, store} = Wasmex.Components.Store.new_wasi(wasi, nil, engine)
          {:ok, instance} = Wasmex.Components.Instance.new(store, component, %{})

          Wasmex.Components.Instance.serve_http(
            instance,
            conn.method,
            conn.request_path,
            conn.req_headers,
            body,
            epoch
          )
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end
end
