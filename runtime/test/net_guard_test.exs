defmodule Workbooks.NetGuardTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Workbooks.NetGuard

  test "ip_allowed? denies internal/sensitive addresses" do
    deny = [
      {127, 0, 0, 1}, {127, 1, 2, 3}, {169, 254, 169, 254}, {169, 254, 0, 1},
      {10, 0, 0, 1}, {172, 16, 0, 1}, {172, 31, 255, 255}, {192, 168, 1, 1},
      {100, 64, 0, 1}, {100, 127, 255, 255}, {0, 0, 0, 0}, {0, 1, 2, 3},
      {255, 255, 255, 255}, {224, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 0},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1}, {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1}, {0xFF02, 0, 0, 0, 0, 0, 0, 1},
      # IPv4-mapped IPv6 of loopback / metadata
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}
    ]

    for ip <- deny, do: refute NetGuard.ip_allowed?(ip), "should DENY #{inspect(ip)}"
  end

  test "ip_allowed? permits public addresses" do
    allow = [
      {8, 8, 8, 8}, {1, 1, 1, 1}, {93, 184, 216, 34}, {140, 82, 112, 3},
      {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}, {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
    ]

    for ip <- allow, do: assert NetGuard.ip_allowed?(ip), "should ALLOW #{inspect(ip)}"
  end

  test "allowed? denies internal URLs (IP literals, no DNS)" do
    refute NetGuard.allowed?("http://169.254.169.254/")
    refute NetGuard.allowed?("http://127.0.0.1:4000/latest/meta-data/")
    refute NetGuard.allowed?("http://10.0.0.5/")
    refute NetGuard.allowed?("https://[::1]/")
    refute NetGuard.allowed?("http://[::ffff:127.0.0.1]/")
  end

  test "allowed? permits public URLs (IP literals)" do
    assert NetGuard.allowed?("http://8.8.8.8/")
    assert NetGuard.allowed?("https://1.1.1.1/")
  end

  test "allowed? denies malformed / hostless input" do
    refute NetGuard.allowed?("not a url")
    refute NetGuard.allowed?("http://")
    refute NetGuard.allowed?("")
    refute NetGuard.allowed?(nil)
  end

  test "RED-TEAM: denies obfuscated/smuggled internal targets (decimal/hex/octal/short IP, userinfo@, v4-mapped)" do
    for url <- [
          "http://2130706433/",                  # decimal int = 127.0.0.1
          "http://0x7f000001/",                   # hex = 127.0.0.1
          "http://0177.0.0.1/",                   # octal octet = 127.0.0.1
          "http://127.1/",                        # short form = 127.0.0.1
          "http://017700000001/",                 # full octal = 127.0.0.1
          "http://trusted.example.com@127.0.0.1/",        # userinfo smuggle -> loopback
          "http://google.com@169.254.169.254/latest/",    # userinfo -> cloud metadata
          "http://169.254.169.254.nip.io.@127.0.0.1/",    # userinfo with internal host
          "http://[::ffff:127.0.0.1]/",           # IPv4-mapped IPv6 loopback
          "http://[::ffff:a9fe:a9fe]/",           # IPv4-mapped IPv6 metadata (169.254.169.254)
          "http://0/",                            # 0 = 0.0.0.0
          "http://[0:0:0:0:0:0:0:1]/"             # expanded ::1
        ] do
      refute NetGuard.allowed?(url), "RED-TEAM bypass not blocked: #{url}"
    end
  end

  test "get/1 denies internal destinations before opening a socket (offline)" do
    # No :httpc call is made for a denied URL — proven by this passing with no network.
    assert {:error, :denied} = NetGuard.get("http://169.254.169.254/latest/meta-data/")
    assert {:error, :denied} = NetGuard.get("http://127.0.0.1:4000/")
    assert {:error, :denied} = NetGuard.get("http://10.1.2.3/")
    assert {:error, :denied} = NetGuard.get("https://[::1]/")
  end

  test "host_in_allowlist? matches exact / *.suffix / host:port, case-insensitively" do
    allow = ["example.com", "*.api.github.com", "secure.test:443"]
    assert NetGuard.host_in_allowlist?("example.com", allow)
    assert NetGuard.host_in_allowlist?("EXAMPLE.COM", allow)
    assert NetGuard.host_in_allowlist?("v3.api.github.com", allow)
    assert NetGuard.host_in_allowlist?("api.github.com", allow)
    assert NetGuard.host_in_allowlist?("secure.test", allow)
    refute NetGuard.host_in_allowlist?("evil.com", allow)
    refute NetGuard.host_in_allowlist?("github.com", allow)
    refute NetGuard.host_in_allowlist?("x.example.com", allow)
    refute NetGuard.host_in_allowlist?("anything", [])
  end

  test "get with :allow denies a PUBLIC host not on the list (before any socket)" do
    # 8.8.8.8 passes the SSRF floor (public) but is not in the allow-list -> denied. Proves the allow-list
    # is the blocker (distinct from the floor), and it denies before connecting (hermetic).
    assert {:error, :denied} = NetGuard.get("http://8.8.8.8/", allow: ["example.com"])
    assert {:error, :denied} = NetGuard.get("http://1.1.1.1/", allow: ["*.example.com"])
  end

  test "audit: every blocked egress is logged" do
    ssrf = capture_log(fn -> NetGuard.get("http://169.254.169.254/") end)
    assert ssrf =~ "DENY egress" and ssrf =~ "SSRF"

    listed = capture_log(fn -> NetGuard.get("http://8.8.8.8/", allow: ["example.com"]) end)
    assert listed =~ "DENY egress" and listed =~ "allow-list"
  end

  test "REVOCATION: a revoked principal is denied egress before any socket opens" do
    p = "revp-#{System.unique_integer([:positive])}"
    assert :ok = Workbooks.Revocation.revoke(p)
    # 8.8.8.8 would pass the SSRF floor + the allow-list — but the revoked principal short-circuits first
    assert {:error, :revoked} = NetGuard.get("http://8.8.8.8/", principal: p, allow: ["8.8.8.8"])
    assert :ok = Workbooks.Revocation.unrevoke(p)
  end

  test "RATE LIMIT: a principal over its egress budget is denied (DoS floor)" do
    p = "rl-#{System.unique_integer([:positive])}"
    # internal URLs SSRF-deny (so no socket), but the rate counter still ticks; the 3rd call (max 2) is
    # rate-limited BEFORE the SSRF check
    assert {:error, :denied} = NetGuard.get("http://127.0.0.1/", principal: p, rate: {2, 60_000})
    assert {:error, :denied} = NetGuard.get("http://127.0.0.1/", principal: p, rate: {2, 60_000})
    assert {:error, :rate_limited} = NetGuard.get("http://127.0.0.1/", principal: p, rate: {2, 60_000})
  end

  @tag :netdeps
  test "resolve-then-pin — http_get still retrieves real content via the pinned IP; internal stays denied" do
    # the pin rewrites the URL host to the resolved IP + keeps Host: example.com; the server still serves
    assert {:ok, body} = NetGuard.get("http://example.com/")
    assert body =~ "Example Domain"
    assert {:error, :denied} = NetGuard.get("http://169.254.169.254/")
  end
end
