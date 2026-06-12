defmodule Workbooks.UdpBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.UdpBroker

  test "SSRF — internal UDP destinations are denied (hermetic)" do
    assert {:error, :denied} = UdpBroker.request("127.0.0.1", 53, "x")
    assert {:error, :denied} = UdpBroker.request("169.254.169.254", 53, "x")
    assert {:error, :denied} = UdpBroker.request("10.0.0.1", 53, "x")
  end

  test "REVOCATION + RATE gate the UDP broker" do
    p = "udp-#{System.unique_integer([:positive])}"
    Workbooks.Revocation.revoke(p)
    assert {:error, :revoked} = UdpBroker.request("1.1.1.1", 53, "x", principal: p)
    Workbooks.Revocation.unrevoke(p)

    p2 = "udp-#{System.unique_integer([:positive])}"
    # rate counts before the SSRF deny; 2nd internal call (max 1) is rate-limited
    assert {:error, :denied} = UdpBroker.request("127.0.0.1", 53, "x", principal: p2, rate: {1, 60_000})
    assert {:error, :rate_limited} = UdpBroker.request("127.0.0.1", 53, "x", principal: p2, rate: {1, 60_000})
  end

  @tag :netdeps
  test "real UDP query/response — a DNS A-query to a public resolver returns a DNS reply (brokered, pinned)" do
    # minimal DNS query for example.com A record, txid 0x1234, recursion-desired
    header = <<0x1234::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16>>
    qname = <<7, "example"::binary, 3, "com"::binary, 0>>
    query = header <> qname <> <<1::16, 1::16>>

    assert {:ok, resp} = UdpBroker.request("1.1.1.1", 53, query, timeout: 5_000)
    # a valid DNS reply echoes our transaction id and carries at least one answer
    assert <<0x1234::16, _flags::16, _qd::16, ancount::16, _rest::binary>> = resp
    assert ancount > 0
  end
end
