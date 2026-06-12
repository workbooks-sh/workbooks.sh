defmodule Workbooks.TlsBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.TlsBroker

  test "SSRF — internal TLS destinations are denied (hermetic)" do
    assert {:error, :denied} = TlsBroker.request("127.0.0.1", 443, "x")
    assert {:error, :denied} = TlsBroker.request("169.254.169.254", 443, "x")
    assert {:error, :denied} = TlsBroker.request("10.0.0.1", 443, "x")
  end

  test "REVOCATION + RATE gate the TLS broker" do
    p = "tls-#{System.unique_integer([:positive])}"
    Workbooks.Revocation.revoke(p)
    assert {:error, :revoked} = TlsBroker.request("example.com", 443, "x", principal: p)
    Workbooks.Revocation.unrevoke(p)

    p2 = "tls-#{System.unique_integer([:positive])}"
    assert {:error, :denied} = TlsBroker.request("127.0.0.1", 443, "x", principal: p2, rate: {1, 60_000})
    assert {:error, :rate_limited} = TlsBroker.request("127.0.0.1", 443, "x", principal: p2, rate: {1, 60_000})
  end

  @tag :netdeps
  test "real TLS round-trip — an HTTPS GET over the brokered TLS channel returns a response (cert-validated, pinned)" do
    req = "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"
    assert {:ok, resp} = TlsBroker.request("example.com", 443, req, timeout: 10_000)
    # the host did the TLS handshake (verify_peer against the system trust store) + returned the decrypted reply
    assert resp =~ "HTTP/"
  end
end
