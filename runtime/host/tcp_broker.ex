defmodule Workbooks.TcpBroker do
  @moduledoc """
  wb-broker RAW-TCP request/response (host_http_get's lower-level sibling) — a guest hands the host a
  destination + request bytes; the host opens the TCP connection, sends, reads the reply, closes, and
  returns the bytes. The guest never opens a socket. One-shot request/response (stateless), which covers
  most line protocols (HTTP/1, Redis RESP, simple wire protocols) without persistent-connection complexity.

  Security cadence:
    * SSRF + RESOLVE-THEN-PIN — the host resolves the name ONCE, refuses any internal/non-routable address,
      and CONNECTS TO THE PINNED IP (not the hostname), so a DNS rebind between check and connect can't
      redirect to an internal target (the defense the TLS-bearing http path couldn't do).
    * per-principal REVOCATION + RATE; response SIZE cap (DoS floor); connect/read TIMEOUT (slowloris floor).
  """
  require Logger

  @default_max_response 1_048_576

  @doc "Brokered TCP request/response. opts: :principal, :rate {max,window}, :max_response, :timeout."
  def request(host, port, data, opts \\ [])
      when is_binary(host) and is_integer(port) and is_binary(data) do
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate)
    max = Keyword.get(opts, :max_response, @default_max_response)
    timeout = Keyword.get(opts, :timeout, 10_000)

    cond do
      principal && Workbooks.Revocation.revoked?(principal) ->
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        {:error, :rate_limited}

      true ->
        case Workbooks.NetGuard.resolve_allowed_ip(host) do
          {:ok, ip} ->
            do_request(ip, port, data, max, timeout)

          :error ->
            Logger.warning("wb-broker: DENY tcp #{host}:#{port} — SSRF (internal/non-routable/unresolved)")
            {:error, :denied}
        end
    end
  end

  defp do_request(ip, port, data, max, timeout) do
    # connect to the PINNED resolved IP tuple, never the hostname
    case :gen_tcp.connect(ip, port, [:binary, active: false, packet: :raw], timeout) do
      {:ok, sock} ->
        :ok = :gen_tcp.send(sock, data)
        resp = recv_all(sock, max, timeout, "")
        :gen_tcp.close(sock)
        {:ok, resp}

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp recv_all(sock, max, timeout, acc) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, chunk} ->
        acc = acc <> chunk
        if byte_size(acc) >= max, do: binary_part(acc, 0, max), else: recv_all(sock, max, timeout, acc)

      {:error, _} ->
        acc
    end
  end

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}
end
