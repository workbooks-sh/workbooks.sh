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

  @tag :netdeps
  test "RED-TEAM: a public URL that REDIRECTS to an internal target never reaches it (each hop re-validated)" do
    # autoredirect is off; NetGuard follows 3xx MANUALLY and re-checks allowed?/allow-list on EVERY hop, so a
    # public host redirecting to cloud metadata can't smuggle the guest there. httpbin issues the 302; we
    # assert the internal target is NEVER reached (denied), regardless of whether httpbin itself is reachable.
    redirect =
      "http://httpbin.org/redirect-to?url=" <> URI.encode_www_form("http://169.254.169.254/latest/meta-data/")

    # The security property is "the INTERNAL TARGET is never fetched" — NOT "the call fails". When httpbin is up
    # and 302s, NetGuard re-checks the hop and returns {:error, :denied}. When httpbin is flaky (503/down), the
    # call returns {:ok, <httpbin's own page>} — still safe, the metadata service was never reached. Assert the
    # real invariant (no metadata content leaks) so a flaky external service can't masquerade as a regression.
    case NetGuard.get(redirect) do
      {:error, _} ->
        :ok

      {:ok, body} ->
        refute body =~ "meta-data" or body =~ "ami-id" or body =~ "instance-id" or body =~ "iam/",
               "redirect-to-internal must not return cloud-metadata content"
    end
  end

  @tag :netdeps
  test "RED-TEAM: https egress is cert-VERIFIED (MITM defense) and IP-pinned (DNS-rebinding defense)" do
    # a valid public https host works — the pin + SNI + verify_peer don't break normal TLS
    assert {:ok, _body} = NetGuard.get("https://example.com/")

    # an INVALID cert is REJECTED by verify_peer. :httpc's DEFAULT (verify_none) would ACCEPT these — that was
    # the MITM hole. expired + self-signed both fail the chain/validity check against the system trust store.
    assert {:error, _} = NetGuard.get("https://expired.badssl.com/")
    assert {:error, _} = NetGuard.get("https://self-signed.badssl.com/")

    # and https to an internal target is still SSRF-blocked before any socket opens
    assert {:error, :denied} = NetGuard.get("https://169.254.169.254/")
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

  test "request/3 — full-method brokered client keeps SSRF on EVERY method (hermetic)" do
    # POST/PUT/DELETE to internal targets must be SSRF-denied just like GET — before any socket opens.
    assert {:error, :denied} = NetGuard.request(:post, "http://127.0.0.1/", body: "x")
    assert {:error, :denied} = NetGuard.request(:put, "http://169.254.169.254/latest/", body: "y")
    assert {:error, :denied} = NetGuard.request(:delete, "http://10.0.0.1/")
    # off-allow-list public host denied for a POST too
    assert {:error, :denied} = NetGuard.request(:post, "http://8.8.8.8/", body: "x", allow: ["example.com"])
  end

  @tag :netdeps
  test "request/3 — a GET to a public host returns status + headers + body" do
    assert {:ok, %{status: 200, body: body, headers: hdrs}} =
             NetGuard.request(:get, "http://example.com/")

    assert body =~ "Example Domain"
    assert is_list(hdrs)
  end

  @tag :netdeps
  test "request/3 — RESPONSE BYTE CAP truncates an oversized body (DoS floor for the brokered transport)" do
    # a tiny max_bytes forces truncation even on example.com; proves the cap bounds what we forward/store so a
    # malicious-but-allowed host can't fill disk via the PyNet file transport or balloon a guest.
    assert {:ok, %{body: body, truncated: true}} =
             NetGuard.request(:get, "http://example.com/", max_bytes: 64)

    assert byte_size(body) == 64
  end
end
