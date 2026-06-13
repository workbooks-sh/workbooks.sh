defmodule Workbooks.TcpServeBroker do
  @moduledoc """
  wb-broker RAW-TCP INBOUND (keystone goal 4, extended past wasi:http) — the host-as-TCP-listener server flip.
  Lets a TCP line/binary-protocol server (a Redis-class daemon, an echo/telemetry service) run brokered: the
  HOST owns the listening socket (the privileged op a sandboxed guest cannot have — guest listeners are denied
  at socket_addr_check), accepts each connection, hands the request BYTES to a guest handler, and writes back
  the guest's response BYTES. The guest never touches a socket; only its `handler(binary) -> binary` logic
  runs. This is the raw-TCP sibling of the wasi:http app-host (ServeBroker/ComponentPlug fronted by Bandit).

  Security cadence (mirrors the wasi:http app-host):
    * PER-CLIENT RATE — a flood from one remote IP is throttled (RateLimiter), so it can't exhaust the host.
    * REQUEST BYTE CAP — the host reads at most `:max_request_bytes` (a clean close, never unbounded buffering).
    * MID-FLIGHT REVOCATION — once the `:serve_id` is revoked, new connections are refused (the server keeps
      listening; only this hosted service is gated).
    * AUDIT — refusals are recorded via BrokerAudit (:tcp_serve).
  The handler is a `(binary -> binary)` function — in production it is backed by a sandboxed guest (e.g.
  ServeBroker.dispatch into a wasm handler); a plain function is the mechanism + the test seam.
  """
  require Logger

  @doc """
  Start a brokered TCP server on `:port`. opts:
    * `:handler` (required) — `(request_binary -> response_binary)`, the brokered guest logic.
    * `:serve_id` — revocation principal + per-client rate key namespace (default a random id).
    * `:max_request_bytes` — cap the host-side read per connection (default 1 MiB).
    * `:rate` — `{max, window_ms}` per-client (remote IP) connection rate (default the broker floor).
    * `:ip` — bind address (default {127, 0, 0, 1} — loopback; the host owns exposure, not the guest).
  Returns `{:ok, listen_socket}`; close it (or `stop/1`) to shut the server down.
  """
  def start(opts) do
    handler = Keyword.fetch!(opts, :handler)
    serve_id = Keyword.get(opts, :serve_id, "tcpserve-#{System.unique_integer([:positive])}")
    max_req = Keyword.get(opts, :max_request_bytes, 1024 * 1024)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)

    case :gen_tcp.listen(port, [:binary, ip: ip, active: false, packet: :raw, reuseaddr: true, backlog: 64]) do
      {:ok, lsock} ->
        cfg = %{handler: handler, serve_id: serve_id, max_req: max_req, rate: rate}
        # unlinked acceptor so it survives the caller; it exits when the listen socket is closed
        spawn(fn -> accept_loop(lsock, cfg) end)
        {:ok, lsock}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Build a handler backed by a SANDBOXED WASM COMMAND (the real brokered guest): each connection's request
  bytes become the command's stdin, and its stdout is the response. The command runs in its OWN isolated
  wasm instance via CommandRegistry (the full exec sandbox) — so a TCP server's request/response logic is a
  guest that never touches the socket. `name`/`argv` are the registered command + its args.
  """
  def command_handler(name, argv \\ []) when is_binary(name) and is_list(argv) do
    fn request ->
      case Workbooks.CommandRegistry.run(name, request, argv) do
        {:ok, out} when is_binary(out) -> out
        _ -> <<>>
      end
    end
  end

  @doc "Stop a server by closing its listen socket (the accept loop then exits)."
  def stop(lsock), do: :gen_tcp.close(lsock)

  @doc "The bound port of a listen socket (useful when started on port 0)."
  def port(lsock) do
    case :inet.port(lsock) do
      {:ok, p} -> p
      _ -> nil
    end
  end

  defp accept_loop(lsock, cfg) do
    case :gen_tcp.accept(lsock) do
      {:ok, conn} ->
        # handle each connection in its own process so a slow client can't block the acceptor
        spawn(fn -> serve_conn(conn, cfg) end)
        accept_loop(lsock, cfg)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(lsock, cfg)
    end
  end

  defp serve_conn(conn, %{handler: handler, serve_id: serve_id, max_req: max_req, rate: rate}) do
    client_ip =
      case :inet.peername(conn) do
        {:ok, {addr, _port}} -> addr |> :inet.ntoa() |> to_string()
        _ -> "unknown"
      end

    cond do
      # mid-flight revocation: the host keeps listening, but this hosted service refuses new connections
      Workbooks.Revocation.revoked?(serve_id) ->
        Workbooks.BrokerAudit.record(:tcp_serve, :deny, :revoked, "#{serve_id}")
        :gen_tcp.close(conn)

      # per-client (remote IP) connection rate floor — a flood from one client can't exhaust the host
      rate && rate_denied?("tcpserve:#{serve_id}:#{client_ip}", rate) ->
        Workbooks.BrokerAudit.record(:tcp_serve, :deny, :rate_limited, client_ip)
        :gen_tcp.close(conn)

      true ->
        # read the request up to the byte cap (a clean close past it, never unbounded buffering), broker the
        # bytes to the guest handler, write back the response. One request/response per connection (the
        # common line/binary-protocol shape); keep-alive is a later refinement.
        case read_capped(conn, max_req, <<>>) do
          {:ok, request} ->
            response =
              try do
                handler.(request)
              rescue
                _ -> <<>>
              catch
                _, _ -> <<>>
              end

            if is_binary(response) and response != "", do: :gen_tcp.send(conn, response)
            :gen_tcp.close(conn)

          {:error, :too_large} ->
            :gen_tcp.close(conn)
        end
    end
  end

  # read until the client stops sending (a short recv timeout marks request end) or the cap is hit
  defp read_capped(conn, max, acc) do
    if byte_size(acc) > max do
      {:error, :too_large}
    else
      case :gen_tcp.recv(conn, 0, 300) do
        {:ok, data} -> read_capped(conn, max, acc <> data)
        {:error, :timeout} -> {:ok, acc}
        {:error, _closed} -> {:ok, acc}
      end
    end
  end

  defp rate_denied?(key, {max, window}),
    do: Workbooks.RateLimiter.check(key, max, window) == {:error, :rate_limited}
end
