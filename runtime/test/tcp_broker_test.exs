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

  test "SSRF — internal TCP destinations are denied before any connect (hermetic)" do
    assert {:error, :denied} = TcpBroker.request("127.0.0.1", 22, "x")
    assert {:error, :denied} = TcpBroker.request("169.254.169.254", 80, "x")
    assert {:error, :denied} = TcpBroker.request("10.0.0.1", 6379, "x")
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
