defmodule Workbooks.UdpBroker do
  @moduledoc """
  wb-broker UDP egress (host_tcp's datagram sibling) — a guest hands the host a destination + a datagram;
  the host sends it (from a host-opened socket, to a resolve-then-pinned, SSRF-checked IP) and returns the
  first reply datagram. The guest never opens a socket. One-shot send/recv covers query/response UDP
  protocols (DNS, NTP, STUN, simple game/telemetry).

  Same security cadence as TcpBroker: SSRF + RESOLVE-THEN-PIN (connect to the checked IP, not the hostname,
  closing DNS-rebinding), per-principal revocation + rate, response size cap, recv timeout.
  """
  require Logger

  @default_max_response 65_535

  @doc "Brokered UDP send + receive-one. opts: :principal, :rate {max,window}, :max_response, :timeout."
  def request(host, port, datagram, opts \\ [])
      when is_binary(host) and is_integer(port) and is_binary(datagram) do
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
    allow = Keyword.get(opts, :allow, nil)
    max = Keyword.get(opts, :max_response, @default_max_response)
    timeout = Keyword.get(opts, :timeout, 5_000)

    cond do
      principal && Workbooks.Revocation.revoked?(principal) ->
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        {:error, :rate_limited}

      not Workbooks.NetGuard.dest_allowed?(host, port, allow) ->
        Workbooks.BrokerAudit.record(:udp, :deny, :allowlist, "#{host}:#{port}")
        {:error, :denied}

      true ->
        case Workbooks.NetGuard.resolve_allowed_ip(host) do
          {:ok, ip} ->
            do_request(ip, port, datagram, max, timeout)

          :error ->
            Workbooks.BrokerAudit.record(:udp, :deny, :ssrf, "#{host}:#{port}")
            Logger.warning("wb-broker: DENY udp #{host}:#{port} — SSRF (internal/non-routable/unresolved)")
            {:error, :denied}
        end
    end
  end

  defp do_request(ip, port, datagram, max, timeout) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, sock} ->
        # wb-8w8x: CONNECT the socket to the pinned peer so the kernel only delivers datagrams FROM {ip,port}
        # (the old unconnected socket returned the first datagram from ANY source — spoofable reply injection).
        res =
          with :ok <- :gen_udp.connect(sock, ip, port),
               :ok <- :gen_udp.send(sock, datagram),
               {:ok, {addr, src_port, data}} <- :gen_udp.recv(sock, 0, timeout) do
            # belt-and-suspenders: even with connect, verify the reply came from the pinned peer
            if addr == ip and src_port == port do
              {:ok, cap(data, max)}
            else
              {:error, :spoofed_source}
            end
          else
            {:error, reason} -> {:error, {:recv_failed, reason}}
          end

        :gen_udp.close(sock)
        res

      {:error, reason} ->
        {:error, {:open_failed, reason}}
    end
  end

  defp cap(data, max) when byte_size(data) > max, do: binary_part(data, 0, max)
  defp cap(data, _max), do: data

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}
end
