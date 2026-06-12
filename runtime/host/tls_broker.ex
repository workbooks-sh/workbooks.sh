defmodule Workbooks.TlsBroker do
  @moduledoc """
  wb-broker TLS egress (host_tcp's encrypted sibling) — a guest hands the host a destination + plaintext
  request bytes; the host opens a TLS connection (verifying the server cert against the hostname), sends the
  bytes, and returns the decrypted reply. The guest gets a secure channel WITHOUT shipping a TLS stack or
  crypto — HTTPS / SMTPS / any TLS line protocol becomes reachable for tiny guests.

  Security cadence (mirrors TcpBroker): SSRF + RESOLVE-THEN-PIN (connect to the checked IP, with SNI = the
  hostname so cert validation still binds the connection — a rebind to internal fails the handshake),
  verify_peer against the system trust store, per-principal revocation + rate, response size cap, timeout.
  """
  require Logger

  @default_max_response 1024 * 1024

  @doc "Brokered TLS request/response. opts: :principal, :rate {max,window}, :max_response, :timeout."
  def request(host, port, data, opts \\ [])
      when is_binary(host) and is_integer(port) and is_binary(data) do
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
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
            do_request(ip, host, port, data, max, timeout)

          :error ->
            Workbooks.BrokerAudit.record(:tls, :deny, :ssrf, "#{host}:#{port}")
            Logger.warning("wb-broker: DENY tls #{host}:#{port} — SSRF (internal/non-routable/unresolved)")
            {:error, :denied}
        end
    end
  end

  defp do_request(ip, host, port, data, max, timeout) do
    _ = Application.ensure_all_started(:ssl)

    # connect to the PINNED ip, but keep SNI = hostname so verify_peer validates the cert for the hostname
    opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 10
    ]

    case :ssl.connect(ip, port, opts, timeout) do
      {:ok, sock} ->
        :ok = :ssl.send(sock, data)
        res = recv_all(sock, timeout, max, [])
        :ssl.close(sock)
        res

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp recv_all(sock, timeout, max, acc) do
    case :ssl.recv(sock, 0, timeout) do
      {:ok, chunk} ->
        acc = [acc | chunk]

        if IO.iodata_length(acc) >= max do
          {:ok, binary_part(:erlang.iolist_to_binary(acc), 0, max)}
        else
          recv_all(sock, timeout, max, acc)
        end

      {:error, :closed} ->
        {:ok, :erlang.iolist_to_binary(acc)}

      {:error, :timeout} ->
        {:ok, :erlang.iolist_to_binary(acc)}

      {:error, reason} ->
        if acc == [], do: {:error, {:recv_failed, reason}}, else: {:ok, :erlang.iolist_to_binary(acc)}
    end
  end

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}
end
