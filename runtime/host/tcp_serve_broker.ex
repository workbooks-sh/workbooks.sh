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
    # absolute wall-clock deadline for reading the WHOLE request — a slowloris dripping bytes under the per-
    # recv timeout would otherwise hold a handler process indefinitely (DoS the directive names).
    max_req_ms = Keyword.get(opts, :max_request_ms, 30_000)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
    # GLOBAL concurrent-connection cap (across ALL clients) — bounds total handler processes against a
    # distributed flood (many IPs each under the per-client rate). An atomics counter (lock-free).
    max_concurrent = Keyword.get(opts, :max_concurrent, 256)
    # PER-CLIENT concurrent-connection sub-cap (DoS fairness) — default ~1/4 of the global pool (min 4) so no
    # single remote IP can monopolize the listener.
    max_per_client = Keyword.get(opts, :max_per_client, max(4, div(max_concurrent, 4)))
    serve_token = System.unique_integer([:positive])
    conns = :atomics.new(1, signed: false)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)

    case :gen_tcp.listen(port, [:binary, ip: ip, active: false, packet: :raw, reuseaddr: true, backlog: 64]) do
      {:ok, lsock} ->
        cfg = %{
          handler: handler,
          serve_id: serve_id,
          max_req: max_req,
          max_req_ms: max_req_ms,
          rate: rate,
          max_concurrent: max_concurrent,
          max_per_client: max_per_client,
          serve_token: serve_token,
          conns: conns
        }
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

  SANDBOX-FROM-EGRESS (the inbound serving guest must NOT become an SSRF pivot): the served command runs with
  NO network by construction — the wasmtime CLI lane is invoked WITHOUT any inherit-network/-S http flag, and
  the dock lane defaults to the `:minimal` profile (Policy.allow_http? false, no host_http_get import). A
  malicious server guest therefore cannot reach the network at all; if a server genuinely needs to call out,
  that is a DELIBERATE grant routing through the brokered+SSRF-guarded egress path, never ambient.
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

  defp accept_loop(lsock, %{conns: conns, max_concurrent: max_conc} = cfg) do
    case :gen_tcp.accept(lsock) do
      {:ok, conn} ->
        client_ip = peer_ip(conn)

        cond do
          # GLOBAL concurrency gate: bounds total handler processes vs a distributed flood (many IPs).
          :atomics.add_get(conns, 1, 1) > max_conc ->
            :atomics.sub(conns, 1, 1)
            Workbooks.BrokerAudit.record(:tcp_serve, :deny, :max_concurrent, nil)
            :gen_tcp.close(conn)

          # PER-CLIENT concurrency gate (DoS FAIRNESS): one IP can't hold more than its share of the global
          # pool and starve everyone else — bounds concurrent connections per remote IP, not just total.
          client_conn_count(cfg, client_ip) >= cfg.max_per_client ->
            :atomics.sub(conns, 1, 1)
            Workbooks.BrokerAudit.record(:tcp_serve, :deny, :max_per_client, client_ip)
            :gen_tcp.close(conn)

          true ->
            client_conn_inc(cfg, client_ip)

            spawn(fn ->
              try do
                serve_conn(conn, cfg, client_ip)
              after
                :atomics.sub(conns, 1, 1)
                client_conn_dec(cfg, client_ip)
              end
            end)
        end

        accept_loop(lsock, cfg)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(lsock, cfg)
    end
  end

  defp serve_conn(conn, %{handler: handler, serve_id: serve_id, max_req: max_req, max_req_ms: max_req_ms, rate: rate}, client_ip) do
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
        # read the request up to the byte cap AND an absolute wall-clock deadline (slowloris floor), broker the
        # bytes to the guest handler, write back the response. One request/response per connection.
        deadline = System.monotonic_time(:millisecond) + max_req_ms

        case read_capped(conn, max_req, deadline, <<>>) do
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

          {:error, _reason} ->
            :gen_tcp.close(conn)
        end
    end
  end

  # read until the client stops sending (a short recv gap marks request end) or a limit trips: the byte cap OR
  # the ABSOLUTE deadline (a slowloris dripping under the per-recv timeout can't hold the process past it).
  defp read_capped(conn, max, deadline, acc) do
    cond do
      byte_size(acc) > max ->
        {:error, :too_large}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        # bound the per-recv wait by the remaining time to the deadline (so the deadline is honored promptly)
        remaining = max(0, deadline - System.monotonic_time(:millisecond))
        wait = min(300, remaining)

        case :gen_tcp.recv(conn, 0, wait) do
          {:ok, data} -> read_capped(conn, max, deadline, acc <> data)
          # a recv gap (no data within `wait`) marks the request complete — but only if we actually have data;
          # an empty-and-still-before-deadline gap loops so a deadline-exceeding slow client is caught above.
          {:error, :timeout} when acc != <<>> -> {:ok, acc}
          {:error, :timeout} -> read_capped(conn, max, deadline, acc)
          {:error, _closed} -> {:ok, acc}
        end
    end
  end

  defp rate_denied?(key, {max, window}),
    do: Workbooks.RateLimiter.check(key, max, window) == {:error, :rate_limited}

  defp peer_ip(conn) do
    case :inet.peername(conn) do
      {:ok, {addr, _port}} -> addr |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  # per-client live-connection count, keyed by {serve instance, client IP} in the long-lived BrokerTables ETS.
  defp client_conn_count(cfg, ip),
    do: :ets.update_counter(client_table(), {cfg.serve_token, ip}, {2, 0}, {{cfg.serve_token, ip}, 0})

  defp client_conn_inc(cfg, ip),
    do: :ets.update_counter(client_table(), {cfg.serve_token, ip}, {2, 1}, {{cfg.serve_token, ip}, 0})

  defp client_conn_dec(cfg, ip) do
    n = :ets.update_counter(client_table(), {cfg.serve_token, ip}, {2, -1}, {{cfg.serve_token, ip}, 0})
    # prune the row at 0 so an idle client's key doesn't linger (table doesn't grow per distinct IP forever)
    if n <= 0, do: :ets.delete(client_table(), {cfg.serve_token, ip})
    :ok
  end

  defp client_table, do: Workbooks.BrokerTables.ensure(:wb_tcpserve_clients, [:named_table, :public, :set])
end
