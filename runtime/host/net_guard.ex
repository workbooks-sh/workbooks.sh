defmodule Workbooks.NetGuard do
  @moduledoc """
  wb-broker SSRF guard for the HOST-MEDIATED egress path (`host_http_get` in rust_dock/js_dock, which
  does `:httpc.request` on a guest-supplied URL). That path is mediated but had NO destination check —
  a guest could `host_http_get("http://169.254.169.254/")` and the host would fetch cloud metadata.

  `allowed?/1` resolves the URL's host and permits it ONLY if EVERY resolved address is public/routable;
  it denies loopback, RFC1918, link-local (incl. 169.254.169.254), CGNAT, unspecified, broadcast,
  multicast, IPv6 ULA/link-local, and IPv4-mapped forms — mirroring the Rust `wb_ip_allowed` filter on
  the wasi path, so both egress paths enforce the same floor. Deny on resolution failure.

  This is the FLOOR (SSRF). A per-call/per-instance allow-list can layer on top (caller passes it).
  """

  require Logger

  @doc """
  SSRF-guarded HTTP GET — the single choke point for the host-mediated egress path. Denies internal
  destinations (SSRF floor) and, if an `:allow` list is given, non-listed hosts — BEFORE any socket
  opens. Every blocked attempt is AUDIT-logged. Returns `{:ok, body}` | `{:error, reason}`.

  Opts: `:timeout` (ms, default 10_000), `:allow` (host-pattern list — nil = no scoping; the URL host
  must match one of "host" / "*.suffix" / "host:port").
  """
  def get(url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    allow = Keyword.get(opts, :allow, nil)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())

    cond do
      principal && Workbooks.Revocation.revoked?(principal) ->
        Workbooks.BrokerAudit.record(:net, :deny, :revoked)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} — principal revoked")
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        Workbooks.BrokerAudit.record(:net, :deny, :rate_limited)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} — rate limited")
        {:error, :rate_limited}

      true ->
        case do_get(url, timeout, allow, 5) do
          {:ok, _} = ok ->
            Workbooks.BrokerAudit.record(:net, :allow)
            ok

          other ->
            other
        end
    end
  end

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}

  defp do_get(_url, _timeout, _allow, hops) when hops < 0, do: {:error, :too_many_redirects}

  defp do_get(url, timeout, allow, hops) do
    cond do
      not allowed?(url) ->
        Workbooks.BrokerAudit.record(:net, :deny, :ssrf, url)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} — SSRF (internal/non-routable destination)")
        {:error, :denied}

      not host_allowed_by_list?(url, allow) ->
        Workbooks.BrokerAudit.record(:net, :deny, :allowlist, url)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} — host not in allow-list")
        {:error, :denied}

      true ->
        _ = Application.ensure_all_started(:inets)
        _ = Application.ensure_all_started(:ssl)

        # resolve-then-PIN: connect to the IP we just checked, not the hostname (which :httpc would RE-resolve,
        # leaving a DNS-rebind window). For http, swap the URL host for the pinned IP and keep the original
        # Host header for vhost routing. https keeps its SNI hostname — cert validation binds the connection.
        {req_url, req_headers} = pin_for_http(url)

        # autoredirect: false — :httpc would otherwise auto-FOLLOW a 3xx, bypassing the guard if a public
        # URL redirects to an internal one. We follow manually so EVERY hop is re-checked (and bounded).
        case :httpc.request(
               :get,
               {req_url, req_headers},
               [{:timeout, timeout}, {:autoredirect, false}],
               body_format: :binary
             ) do
          {:ok, {{_, status, _}, hdrs, body}} when status in 300..399 ->
            case redirect_target(url, hdrs) do
              nil -> {:ok, body}
              next -> do_get(next, timeout, allow, hops - 1)
            end

          {:ok, {{_, _status, _}, _hdrs, body}} ->
            {:ok, body}

          _ ->
            {:error, :request_failed}
        end
    end
  end

  # Resolve-then-pin for the host_http_get path. http: return the IP-rewritten URL + a Host header carrying
  # the original hostname. https / unresolvable: unchanged (cert validation binds https; allowed? already
  # vetted the host so resolve rarely fails here).
  defp pin_for_http(url) do
    uri = URI.parse(url)

    with "http" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         {:ok, ip} <- resolve_allowed_ip(host) do
      host_hdr = if uri.port in [nil, 80], do: host, else: "#{host}:#{uri.port}"
      pinned = URI.to_string(%{uri | host: :inet.ntoa(ip) |> to_string()})
      {String.to_charlist(pinned), [{~c"host", String.to_charlist(host_hdr)}]}
    else
      _ -> {String.to_charlist(url), []}
    end
  end

  defp redirect_target(base, hdrs) do
    case List.keyfind(hdrs, ~c"location", 0) do
      {_, loc} -> base |> URI.parse() |> URI.merge(to_string(loc)) |> URI.to_string()
      _ -> nil
    end
  end

  # Host allow-list (scoping ON TOP of the SSRF floor). nil = no scoping (any public host). A list means
  # the URL's host must match one pattern. Mirrors the Rust wb_host_in_allowlist on the wasi path.
  defp host_allowed_by_list?(_url, nil), do: true

  defp host_allowed_by_list?(url, patterns) when is_list(patterns) do
    host = URI.parse(url).host || ""
    host_in_allowlist?(host, patterns)
  end

  @doc "Match a host against allow-list patterns: exact \"host\", \"host:port\", or \"*.suffix\" (case-insensitive)."
  def host_in_allowlist?(host, patterns) when is_binary(host) and is_list(patterns) do
    h = host |> String.trim_trailing(".") |> String.downcase()

    Enum.any?(patterns, fn p ->
      pat =
        case String.split(String.downcase(String.trim(p)), ":", parts: 2) do
          [hostpat, port] -> if Integer.parse(port) == :error, do: String.downcase(p), else: hostpat
          [hostpat] -> hostpat
        end

      case pat do
        "*." <> suffix -> h == suffix or String.ends_with?(h, "." <> suffix)
        exact -> h == exact
      end
    end)
  end

  @doc "True only if the URL's host resolves entirely to public, externally-routable addresses."
  def allowed?(url) when is_binary(url) do
    with %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url),
         {:ok, ips} <- resolve(host),
         true <- ips != [] do
      Enum.all?(ips, &ip_allowed?/1)
    else
      _ -> false
    end
  end

  def allowed?(_), do: false

  @doc """
  Resolve `host` and return ONE allowed (public) IP to PIN a connection to — so the caller connects to this
  resolved IP, not the hostname, closing the DNS-rebinding window (resolve-then-pin). Returns `{:ok, ip}`
  (an :inet address tuple) | `:error` (unresolvable, or any resolved address is internal/non-routable).
  """
  def resolve_allowed_ip(host) when is_binary(host) do
    case resolve(host) do
      {:ok, [_ | _] = ips} -> if Enum.all?(ips, &ip_allowed?/1), do: {:ok, hd(ips)}, else: :error
      _ -> :error
    end
  end

  def resolve_allowed_ip(_), do: :error

  # Resolve a host (IP literal or DNS name) to a list of inet address tuples. Tries literal first, then
  # A and AAAA. Deny (empty/error) if nothing resolves.
  defp resolve(host) do
    hl = String.trim(host, "[") |> String.trim_trailing("]") |> String.to_charlist()

    case :inet.parse_address(hl) do
      {:ok, ip} ->
        {:ok, [ip]}

      _ ->
        v4 = case :inet.getaddrs(hl, :inet) do
          {:ok, a} -> a
          _ -> []
        end

        v6 = case :inet.getaddrs(hl, :inet6) do
          {:ok, a} -> a
          _ -> []
        end

        case v4 ++ v6 do
          [] -> :error
          ips -> {:ok, ips}
        end
    end
  end

  @doc "True if this single inet address tuple is public/externally-routable (not internal/sensitive)."
  # IPv4-mapped IPv6 (::ffff:a.b.c.d) → re-check as IPv4 so it can't smuggle an internal target.
  def ip_allowed?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    ip_allowed?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  end

  def ip_allowed?({a, b, _c, _d} = _v4) do
    not (a == 127 or a == 0 or
           a == 10 or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or
           (a == 169 and b == 254) or
           (a == 100 and b in 64..127) or
           a in 224..239 or
           a == 255)
  end

  def ip_allowed?({s0, _s1, _s2, _s3, _s4, _s5, _s6, s7} = v6) do
    not (v6 == {0, 0, 0, 0, 0, 0, 0, 1} or
           v6 == {0, 0, 0, 0, 0, 0, 0, 0} or
           Bitwise.band(s0, 0xFFC0) == 0xFE80 or
           Bitwise.band(s0, 0xFE00) == 0xFC00 or
           Bitwise.band(s0, 0xFF00) == 0xFF00 or
           (s0 == 0 and s7 == 1))
  end

  def ip_allowed?(_), do: false
end
