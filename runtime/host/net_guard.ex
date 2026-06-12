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

  @doc """
  SSRF-guarded HTTP GET — the single choke point for the host-mediated egress path. Denies internal
  destinations BEFORE any socket is opened. Returns `{:ok, body}` | `{:error, :denied | :request_failed}`.
  """
  def get(url, timeout \\ 10_000) when is_binary(url), do: do_get(url, timeout, 5)

  defp do_get(_url, _timeout, hops) when hops < 0, do: {:error, :too_many_redirects}

  defp do_get(url, timeout, hops) do
    if allowed?(url) do
      _ = Application.ensure_all_started(:inets)
      _ = Application.ensure_all_started(:ssl)

      # autoredirect: false — :httpc would otherwise auto-FOLLOW a 3xx, bypassing the guard if a public
      # URL redirects to an internal one. We follow manually so EVERY hop is re-SSRF-checked (and bounded).
      case :httpc.request(
             :get,
             {String.to_charlist(url), []},
             [{:timeout, timeout}, {:autoredirect, false}],
             body_format: :binary
           ) do
        {:ok, {{_, status, _}, hdrs, body}} when status in 300..399 ->
          case redirect_target(url, hdrs) do
            nil -> {:ok, body}
            next -> do_get(next, timeout, hops - 1)
          end

        {:ok, {{_, _status, _}, _hdrs, body}} ->
          {:ok, body}

        _ ->
          {:error, :request_failed}
      end
    else
      {:error, :denied}
    end
  end

  defp redirect_target(base, hdrs) do
    case List.keyfind(hdrs, ~c"location", 0) do
      {_, loc} -> base |> URI.parse() |> URI.merge(to_string(loc)) |> URI.to_string()
      _ -> nil
    end
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
