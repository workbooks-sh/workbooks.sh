defmodule Nexus.Net.Ssrf do
  @moduledoc """
  The ONE host-side SSRF guard (wb-y4md). Every host-brokered egress on behalf of a guest — the Dock
  `fetch`/`get` caps and the curl-impersonate fallback — passes through `allowed?/1` before connecting.

  It mirrors the strong wasi-http guard in the wasmex NIF (`store.rs` `wb_ip_allowed`/`wb_v4_internal`):
  **resolve the host and reject if ANY resolved address is internal.** A literal-hostname string check
  (the old guard) let a public name that *resolves* to `169.254.169.254`/`127.0.0.1`, or an
  alternate-encoded IP, walk straight through — DNS rebinding. Resolving first closes that.

  Deny set: loopback, RFC1918 private, link-local (incl. `169.254`), CGNAT `100.64/10`, unspecified,
  broadcast, documentation, multicast, reserved (`>=240`), and the IPv6 equivalents — with
  IPv4-mapped / 6to4 / NAT64 embedded-IPv4 re-classified so an internal v4 can't smuggle in via a
  global-looking v6. `:httpc` can't pin the connection to the resolved IP, so this is resolve-and-deny
  (not full pinning); the NIF wasi-http path keeps the stronger pinned connection.

  Allowlist: `Nexus.Config.net_allow/0` (a `deploy` block attr, NOT an env var). Empty (the neutral
  default) = allow any PUBLIC host (internal is always denied); non-empty = only those hosts.
  """

  @doc "Is egress to `url` permitted? Scheme + allowlist + resolve-then-check-every-IP."
  def allowed?(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host || ""
    allow = Nexus.Config.net_allow()

    cond do
      uri.scheme not in ["http", "https"] -> false
      host == "" -> false
      allow != [] and host not in allow -> false
      true -> host_resolves_public?(host)
    end
  end

  def allowed?(_), do: false

  # Resolve the host to all A + AAAA addresses; deny if NONE resolve (fail closed) or ANY is internal.
  defp host_resolves_public?(host) do
    case resolve(host) do
      [] -> false
      ips -> not Enum.any?(ips, &ip_internal?/1)
    end
  end

  defp resolve(host) do
    cl = String.to_charlist(host)
    v4 = case :inet.getaddrs(cl, :inet) do
      {:ok, ips} -> ips
      _ -> []
    end

    v6 = case :inet.getaddrs(cl, :inet6) do
      {:ok, ips} -> ips
      _ -> []
    end

    v4 ++ v6
  end

  @doc "Is an `:inet`-style address tuple an internal/non-routable target? (mirrors the NIF deny set)"
  # IPv4 — {a,b,c,d}
  def ip_internal?({a, b, c, d}) do
    v4_internal?(a, b, c, d)
  end

  # IPv6 — {s0..s7}. Re-classify embedded IPv4 first, then check the v6 internal ranges.
  def ip_internal?({_, _, _, _, _, _, _, _} = v6) do
    Enum.any?(embedded_v4s(v6), fn {a, b, c, d} -> v4_internal?(a, b, c, d) end) or v6_internal?(v6)
  end

  def ip_internal?(_), do: true

  defp v4_internal?(a, b, c, d) do
    a == 0 or a == 127 or a == 10 or a >= 240 or
      (a == 172 and b >= 16 and b <= 31) or
      (a == 192 and b == 168) or
      (a == 169 and b == 254) or
      (a == 100 and Bitwise.band(b, 0xC0) == 64) or
      (a == 255 and b == 255 and c == 255 and d == 255) or
      (a >= 224 and a <= 239) or
      (a == 192 and b == 0 and c == 2) or
      (a == 198 and b == 51 and c == 100) or
      (a == 203 and b == 0 and c == 113)
  end

  defp v6_internal?({s0, s1, s2, s3, s4, s5, s6, s7} = v6) do
    v6 == {0, 0, 0, 0, 0, 0, 0, 0} or                     # :: unspecified
      {s0, s1, s2, s3, s4, s5, s6, s7} == {0, 0, 0, 0, 0, 0, 0, 1} or  # ::1 loopback
      Bitwise.band(s0, 0xFF00) == 0xFF00 or               # multicast ff00::/8
      Bitwise.band(s0, 0xFFC0) == 0xFE80 or               # link-local fe80::/10
      Bitwise.band(s0, 0xFE00) == 0xFC00                  # unique-local fc00::/7
  end

  # Re-classify any IPv4 embedded in a v6 address so an internal v4 can't ride in on a global-looking
  # v6: IPv4-mapped ::ffff:a.b.c.d, 6to4 2002:AABB:CCDD::/16, NAT64 64:ff9b::/96.
  defp embedded_v4s({s0, s1, s2, _s3, s4, s5, s6, s7}) do
    mapped = if s4 == 0 and s5 == 0xFFFF, do: [v4_of(s6, s7)], else: []
    sixto4 = if s0 == 0x2002, do: [v4_of(s1, s2)], else: []
    nat64 = if s0 == 0x0064 and s1 == 0xFF9B, do: [v4_of(s6, s7)], else: []
    mapped ++ sixto4 ++ nat64
  end

  defp v4_of(hi, lo) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end
end
