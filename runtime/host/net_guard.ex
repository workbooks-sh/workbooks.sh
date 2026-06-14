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
    # wb-j3n8: cap the body we HOLD/return (parity with request/3, which already
    # caps). Without this a large/hostile upstream balloons host memory even when
    # the caller (e.g. host_http_get) only wants out_cap bytes. Peak RECEIVE RAM
    # (the transient :httpc buffer) is the separate streaming cap, wb-4had.
    max_bytes = Keyword.get(opts, :max_bytes, 32 * 1024 * 1024)

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
          {:ok, body} ->
            Workbooks.BrokerAudit.record(:net, :allow)
            {:ok, cap_body(url, body, max_bytes)}

          other ->
            other
        end
    end
  end

  # Truncate an over-cap body and AUDIT it (observability: a truncation means an
  # upstream exceeded the host memory budget — worth seeing, not silent).
  defp cap_body(url, body, max_bytes) when is_binary(body) do
    if byte_size(body) > max_bytes do
      Logger.warning("wb-broker: TRUNCATED egress body #{inspect(url)} #{byte_size(body)}B → #{max_bytes}B (wb-j3n8 cap)")
      binary_part(body, 0, max_bytes)
    else
      body
    end
  end

  defp cap_body(_url, body, _max_bytes), do: body

  @doc false
  # test seam for the wb-j3n8 body cap
  def cap_body_for_test(body, max_bytes), do: cap_body("test://x", body, max_bytes)

  @doc """
  Brokered HTTP request with an arbitrary METHOD + headers + body — the full-client generalization of `get/2`,
  for tools that need POST/PUT/etc. (and the host half of the Python brokered-transport shim, since a wasip1
  runtime can't connect outbound itself). Same SSRF + resolve-then-pin + allow-list + revocation/rate cadence
  as `get/2` applies to EVERY method. Returns `{:ok, %{status, headers, body}}` | `{:error, reason}`.

  opts: `:headers` ([{k,v} strings]), `:body`, `:content_type` (default "application/octet-stream"),
  `:allow`, `:principal`, `:rate`, `:timeout`.
  """
  def request(method, url, opts \\ []) when is_atom(method) and is_binary(url) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    allow = Keyword.get(opts, :allow, nil)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, nil)
    ctype = Keyword.get(opts, :content_type, "application/octet-stream")
    max_bytes = Keyword.get(opts, :max_bytes, 32 * 1024 * 1024)
    max_redirects = Keyword.get(opts, :max_redirects, 5)

    cond do
      principal && Workbooks.Revocation.revoked?(principal) ->
        Workbooks.BrokerAudit.record(:net, :deny, :revoked, url)
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        Workbooks.BrokerAudit.record(:net, :deny, :rate_limited, url)
        {:error, :rate_limited}

      true ->
        case do_request(method, url, headers, body, ctype, timeout, allow, max_bytes, max_redirects) do
          {:ok, _} = ok ->
            Workbooks.BrokerAudit.record(:net, :allow)
            ok

          other ->
            other
        end
    end
  end

  defp do_request(_m, _u, _h, _b, _c, _t, _a, _mb, hops) when hops < 0,
    do: {:error, :too_many_redirects}

  defp do_request(method, url, headers, body, ctype, timeout, allow, max_bytes, hops) do
    cond do
      # ALLOW-LIST FIRST (DNS-exfil defense): the allow-list match is purely SYNTACTIC (operates on the URL's
      # hostname string, no DNS). allowed?/SSRF RESOLVES the host — so checking it first would send a DNS query
      # for an off-list hostname BEFORE denying it, leaking guest-chosen labels to an attacker's nameserver
      # (e.g. http://stolen-secret.evil.com under allow:[example.com]). Denying off-list hosts here means NO
      # resolution ever happens for them. (When no allow-list is set this is `true`, so behavior is unchanged.)
      not host_allowed_by_list?(url, allow) ->
        Workbooks.BrokerAudit.record(:net, :deny, :allowlist, url)
        {:error, :denied}

      not allowed?(url) ->
        Workbooks.BrokerAudit.record(:net, :deny, :ssrf, url)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} (#{method}) — SSRF")
        {:error, :denied}

      true ->
        _ = Application.ensure_all_started(:inets)
        _ = Application.ensure_all_started(:ssl)
        {req_url, req_headers, extra_opts} = pin_for_http(url)
        http_opts = [{:timeout, timeout}, {:autoredirect, false}] ++ extra_opts
        hdrs = req_headers ++ Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        # :httpc request tuple: {url, headers} for body-less methods, {url, headers, content_type, body} else.
        req =
          if body in [nil, ""],
            do: {req_url, hdrs},
            else: {req_url, hdrs, to_charlist(ctype), body}

        case :httpc.request(method, req, http_opts, body_format: :binary) do
          # REDIRECT-FOLLOWING — autoredirect is off, so :httpc never auto-follows a 3xx into an internal host.
          # We follow MANUALLY: each hop re-enters do_request, which RE-VALIDATES allowed? + the allow-list at
          # the top — so a public URL redirecting to cloud-metadata/RFC1918 is denied at the hop, never reached.
          # Method semantics: 303 (and the de-facto 301/302) demote to GET + drop the body; 307/308 preserve.
          {:ok, {{_, status, _}, resp_hdrs, rbody}} when status in 300..399 and hops > 0 ->
            case redirect_target(url, resp_hdrs) do
              nil ->
                finish(status, resp_hdrs, rbody, max_bytes)

              next ->
                {nmethod, nbody} = redirect_method(status, method, body)
                do_request(nmethod, next, headers, nbody, ctype, timeout, allow, max_bytes, hops - 1)
            end

          {:ok, {{_, status, _}, resp_hdrs, resp_body}} ->
            finish(status, resp_hdrs, resp_body, max_bytes)

          _ ->
            {:error, :request_failed}
        end
    end
  end

  # 303 always → GET; 301/302 are de-facto demoted to GET by browsers/curl for non-GET (we follow suit, dropping
  # the body); 307/308 preserve the original method AND body. Anything else: keep method, drop body.
  defp redirect_method(303, _method, _body), do: {:get, nil}
  defp redirect_method(s, _method, _body) when s in [301, 302], do: {:get, nil}
  defp redirect_method(s, method, body) when s in [307, 308], do: {method, body}
  defp redirect_method(_s, _method, _body), do: {:get, nil}

  defp finish(status, resp_hdrs, resp_body, max_bytes) do
    # RESPONSE BYTE CAP — a malicious-but-allowed host returning a giant body can't be forwarded wholesale (it
    # would fill disk via the PyNet file transport, or balloon a guest's memory). Truncate to max_bytes + flag.
    # NOTE: :httpc buffers the full body in BEAM memory before this point — the cap bounds what we STORE/FORWARD,
    # not peak receive RAM (streaming cap tracked in wb-4had).
    {capped, truncated} =
      if byte_size(resp_body) > max_bytes,
        do: {binary_part(resp_body, 0, max_bytes), true},
        else: {resp_body, false}

    {:ok, %{status: status, headers: resp_hdrs, body: capped, truncated: truncated}}
  end

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}

  defp do_get(_url, _timeout, _allow, hops) when hops < 0, do: {:error, :too_many_redirects}

  defp do_get(url, timeout, allow, hops) do
    cond do
      # ALLOW-LIST FIRST (DNS-exfil defense — see do_request): the syntactic allow-list check runs before the
      # resolving SSRF check, so an off-list hostname is denied WITHOUT a DNS query (no label leak to an
      # attacker nameserver). No-allow-list case is `true` here, so behavior is unchanged.
      not host_allowed_by_list?(url, allow) ->
        Workbooks.BrokerAudit.record(:net, :deny, :allowlist, url)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} — host not in allow-list")
        {:error, :denied}

      not allowed?(url) ->
        Workbooks.BrokerAudit.record(:net, :deny, :ssrf, url)
        Logger.warning("wb-broker: DENY egress #{inspect(url)} — SSRF (internal/non-routable destination)")
        {:error, :denied}

      true ->
        _ = Application.ensure_all_started(:inets)
        _ = Application.ensure_all_started(:ssl)

        # resolve-then-PIN (http AND https): connect to the IP we just checked, not the hostname (which :httpc
        # would RE-resolve, leaving a DNS-rebind window). For https we also pass ssl opts that ENFORCE cert
        # validation (verify_peer) bound to the original HOSTNAME via SNI — without them :httpc https defaults
        # to verify_none (MITM) and re-resolves the host (rebinding). (wb-j3n8 audit: critical egress-ssrf gap.)
        {req_url, req_headers, extra_opts} = pin_for_http(url)

        # autoredirect: false — :httpc would otherwise auto-FOLLOW a 3xx, bypassing the guard if a public
        # URL redirects to an internal one. We follow manually so EVERY hop is re-checked (and bounded).
        case :httpc.request(
               :get,
               {req_url, req_headers},
               [{:timeout, timeout}, {:autoredirect, false}] ++ extra_opts,
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

  # Resolve-then-pin for the host_http_get path (http AND https). Swap the URL host for the validated, pinned
  # IP (so :httpc can't RE-resolve the hostname — closes DNS-rebinding) and keep a Host header for vhost
  # routing. For https we ALSO return ssl options that (a) ENFORCE cert validation (verify_peer against the
  # system trust store) and (b) bind SNI + the hostname-match to the original HOSTNAME, so the cert is
  # validated for the hostname even though the socket connects to the pinned IP. Returns {url, headers, extra}
  # where `extra` is the http_options to append (the {:ssl, _} block for https, [] for http).
  defp pin_for_http(url) do
    uri = URI.parse(url)

    with scheme when scheme in ["http", "https"] <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         {:ok, ip} <- resolve_allowed_ip(host) do
      default_port = if scheme == "https", do: 443, else: 80
      host_hdr = if uri.port in [nil, default_port], do: host, else: "#{host}:#{uri.port}"
      pinned = URI.to_string(%{uri | host: :inet.ntoa(ip) |> to_string()})

      extra =
        if scheme == "https" do
          [
            {:ssl,
             [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: String.to_charlist(host),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ]}
          ]
        else
          []
        end

      {String.to_charlist(pinned), [{~c"host", String.to_charlist(host_hdr)}], extra}
    else
      _ -> {String.to_charlist(url), [], []}
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

  @doc """
  Port-aware destination allow-list for the raw-socket brokers (TCP/UDP/TLS). `nil` = no scoping (any public
  host:port, after the SSRF floor). A list confines the destination: a `"host:port"` pattern must match BOTH
  host and port; a bare `"host"` / `"*.suffix"` pattern matches the host on any port.
  """
  def dest_allowed?(_host, _port, nil), do: true

  def dest_allowed?(host, port, patterns) when is_binary(host) and is_integer(port) and is_list(patterns) do
    h = host |> String.trim_trailing(".") |> String.downcase()

    Enum.any?(patterns, fn p ->
      {hostpat, portpat} =
        case String.split(String.downcase(String.trim(p)), ":", parts: 2) do
          [hp, pp] ->
            case Integer.parse(pp) do
              {n, ""} -> {hp, n}
              _ -> {String.downcase(String.trim(p)), nil}
            end

          [hp] ->
            {hp, nil}
        end

      host_match =
        case hostpat do
          "*." <> suffix -> h == suffix or String.ends_with?(h, "." <> suffix)
          exact -> h == exact
        end

      host_match and (portpat == nil or portpat == port)
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

  @doc """
  Resolve-then-pin an allow-list for the wasip2 RAW-SOCKET path (`WasiP2Options.net_allow`). wasmtime's
  `socket_addr_check` matches the CONNECT IP against the scope (`wb_addr_in_scope` compares `addr.ip()`), so a
  hostname entry can NEVER match a connection — and worse, leaving a hostname in the scope keeps guest DNS
  enabled (`wb_dns_needed`), letting a guest resolve arbitrary names and EXFIL data via DNS before the connect
  is blocked. So we pin host-side: each entry is resolved to a public IP here (SSRF-safe — internal/unresolvable
  hosts are DROPPED), yielding a pure-IP scope that (a) actually matches the guest's connections and (b) makes
  `wb_dns_needed` false → guest name-lookup is DISABLED → no DNS-exfil. `nil`/`[]` pass through unchanged (the
  unscoped case — DNS-exfil is inherent without a scope, exactly as on the HTTP path).

  Returns the pinned `[ip | "ip:port"]` list (or `nil`). An entry that won't resolve to a public IP is omitted
  (fail-closed — better to drop a name than to leave the scope leaky or the connection silently denied).
  """
  def pin_allow_list(nil), do: nil

  def pin_allow_list(allow) when is_list(allow) do
    allow
    |> Enum.flat_map(fn entry ->
      {host, port} = split_host_port(entry)

      case :inet.parse_address(String.to_charlist(host)) do
        # already an IP literal — keep as-is only if it's a public/allowed address (drop internal IPs too)
        {:ok, ip} ->
          if ip_allowed?(ip), do: [entry], else: []

        _ ->
          # a hostname — resolve to a pinned public IP (or drop)
          case resolve_allowed_ip(host) do
            {:ok, ip} -> [with_port(:inet.ntoa(ip) |> to_string(), port)]
            :error -> []
          end
      end
    end)
  end

  # "host" or "host:port" — but NOT a bare IPv6 literal (which contains ':'). Bracketed IPv6 keeps its brackets.
  defp split_host_port(entry) do
    cond do
      String.starts_with?(entry, "[") -> {entry, nil}
      match?({:ok, _}, :inet.parse_address(String.to_charlist(entry))) -> {entry, nil}
      true ->
        case String.split(entry, ":", parts: 2) do
          [h, p] -> {h, p}
          [h] -> {h, nil}
        end
    end
  end

  defp with_port(ip, nil), do: ip
  defp with_port(ip, port), do: "#{ip}:#{port}"

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
