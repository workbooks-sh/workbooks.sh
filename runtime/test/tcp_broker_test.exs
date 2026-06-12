defmodule Workbooks.TcpBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.{TcpBroker, NetGuard}

  test "resolve_allowed_ip PINS a public IP, refuses internal (resolve-then-pin)" do
    assert {:ok, {8, 8, 8, 8}} = NetGuard.resolve_allowed_ip("8.8.8.8")
    assert :error = NetGuard.resolve_allowed_ip("127.0.0.1")
    assert :error = NetGuard.resolve_allowed_ip("169.254.169.254")
    assert :error = NetGuard.resolve_allowed_ip("10.0.0.1")
    assert :error = NetGuard.resolve_allowed_ip("[::1]")
  end

  test "DEFAULT RATE FLOOR is enforced — a broker call with NO explicit :rate still throttles (DoS floor)" do
    {max, window} = Workbooks.RateLimiter.default_quota()
    p = "defrate-#{System.unique_integer([:positive])}"
    # ensure the table exists, then pre-fill this tenant's CURRENT-window bucket to the ceiling
    Workbooks.RateLimiter.check(p, max, window)
    bucket = div(System.monotonic_time(:millisecond), window)
    :ets.insert(:wb_ratelimit, {{p, bucket}, max})

    # NO :rate passed -> the broker falls back to the default floor -> rate-limited before the SSRF/connect
    assert {:error, :rate_limited} = TcpBroker.request("1.1.1.1", 80, "x", principal: p)
  end

  test "SSRF — internal TCP destinations are denied before any connect (hermetic)" do
    assert {:error, :denied} = TcpBroker.request("127.0.0.1", 22, "x")
    assert {:error, :denied} = TcpBroker.request("169.254.169.254", 80, "x")
    assert {:error, :denied} = TcpBroker.request("10.0.0.1", 6379, "x")
  end

  test "wb-8w8x: per-instance {host,port} ALLOW-LIST confines TCP egress (hermetic — denied before connect)" do
    # a public host NOT on the granted list is denied (the SSRF floor alone would have let it through)
    assert {:error, :denied} = TcpBroker.request("1.1.1.1", 80, "x", allow: ["8.8.8.8:53"])
    # right host, WRONG port -> denied (port-aware)
    assert {:error, :denied} = TcpBroker.request("8.8.8.8", 80, "x", allow: ["8.8.8.8:53"])
    # NetGuard.dest_allowed? unit: host+port match, host-only pattern, wildcard suffix
    assert NetGuard.dest_allowed?("8.8.8.8", 53, ["8.8.8.8:53"])
    assert NetGuard.dest_allowed?("api.example.com", 443, ["api.example.com"])
    assert NetGuard.dest_allowed?("x.example.com", 443, ["*.example.com"])
    refute NetGuard.dest_allowed?("evil.com", 443, ["*.example.com"])
    assert NetGuard.dest_allowed?("anything", 1, nil), "nil = no scoping"
  end

  test "REVOCATION + RATE gate the TCP broker" do
    p = "tcp-#{System.unique_integer([:positive])}"
    Workbooks.Revocation.revoke(p)
    assert {:error, :revoked} = TcpBroker.request("8.8.8.8", 80, "x", principal: p)
    Workbooks.Revocation.unrevoke(p)

    p2 = "tcp-#{System.unique_integer([:positive])}"
    # rate counts before the SSRF deny; 2nd call (max 1) is rate-limited
    assert {:error, :denied} = TcpBroker.request("127.0.0.1", 80, "x", principal: p2, rate: {1, 60_000})
    assert {:error, :rate_limited} = TcpBroker.request("127.0.0.1", 80, "x", principal: p2, rate: {1, 60_000})
  end

  @tag :netdeps
  test "raw TCP request/response to a PUBLIC host works (brokered, SSRF-safe, pinned)" do
    req = "GET / HTTP/1.0\r\nHost: one.one.one.one\r\n\r\n"
    assert {:ok, resp} = TcpBroker.request("1.1.1.1", 80, req, timeout: 8_000)
    assert resp =~ "HTTP/"
  end
end
