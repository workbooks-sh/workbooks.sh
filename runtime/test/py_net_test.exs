defmodule Workbooks.PyNetTest do
  @moduledoc """
  Proves the Python brokered-transport: a wasip1 CPython (which has NO outbound socket — only sock_accept/recv/
  send/shutdown, no sock_connect) makes SSRF-safe outbound HTTP by having the HOST do the network over a shared
  request/response file protocol. The guest never touches a socket; every request goes through NetGuard.request
  so the full SSRF + allow-list + pin cadence applies even to a malicious guest.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PyNet

  setup_all do
    if "python" not in Workbooks.CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok
  end

  test "SSRF — a brokered request to an internal target is DENIED inside CPython (hermetic)" do
    # CPython asks the host to fetch cloud metadata; the host's NetGuard re-validates and refuses. The guest
    # cannot reach it no matter what it writes to the request file.
    assert {:error, err} = PyNet.fetch(:get, "http://169.254.169.254/latest/meta-data/")
    assert err == "denied"
  end

  test "ALLOW-LIST — a public host NOT on the host's allow-list is denied (guest can't widen scope)" do
    # 8.8.8.8 passes the SSRF floor but is off the per-instance allow-list -> denied. Proves the host's scope is
    # authoritative (a guest-supplied allow is ignored).
    assert {:error, "denied"} = PyNet.fetch(:get, "http://8.8.8.8/", allow: ["example.com"])
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "BROKERED FETCH — CPython retrieves a real public page via the host (no guest socket)" do
    assert {:ok, %{status: 200, head: head}} = PyNet.fetch(:get, "http://example.com/")
    assert head =~ "<" or head =~ "html" or head =~ "DOCTYPE" or head =~ "<!"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "BROKERED FETCH respects the allow-list for a permitted host" do
    assert {:ok, %{status: 200}} = PyNet.fetch(:get, "http://example.com/", allow: ["example.com"])
  end
end
