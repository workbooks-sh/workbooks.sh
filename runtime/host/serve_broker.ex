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

  @doc "Dispatch one request to the guest's `handle` export; returns {:ok, response} | {:error, reason}."
  def dispatch(serve_id, pid, request, timeout \\ 10_000) when is_binary(request) do
    put({serve_id, :req}, request)
    delete({serve_id, :resp})

    case Wasmex.call_function(pid, "handle", [], timeout) do
      {:ok, _} -> {:ok, lookup({serve_id, :resp}) || ""}
      {:error, reason} -> {:error, reason}
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
    {:ok, body, conn} = read_body(conn)
    req = ServeBroker.encode_http_request(conn.method, conn.request_path, conn.req_headers, body)

    case ServeBroker.dispatch(serve_id, pid, req) do
      {:ok, resp} ->
        {status, headers, out} = ServeBroker.decode_http_response(resp)
        conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
        send_resp(conn, status, out)

      {:error, _} ->
        send_resp(conn, 502, "guest handler error")
    end
  end
end
