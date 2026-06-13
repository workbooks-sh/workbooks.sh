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

  test "RED-TEAM — every obfuscated/smuggled internal target is DENIED through the guest transport (hermetic)" do
    # the transport is a NEW attack surface; prove the SSRF floor still applies END-TO-END through CPython (not
    # just at NetGuard) for the full obfuscation set — IP literals, decimal/hex/octal, short-form, userinfo@,
    # IPv6 loopback + v4-mapped. A red-team guest writing ANY of these to the request file still can't reach it.
    targets = [
      "http://127.0.0.1/",
      "http://2130706433/",
      "http://0x7f000001/",
      "http://0177.0.0.1/",
      "http://127.1/",
      "http://trusted.example.com@127.0.0.1/",
      "http://google.com@169.254.169.254/latest/",
      "http://[::1]/",
      "http://[::ffff:127.0.0.1]/",
      "http://[::ffff:a9fe:a9fe]/",
      "http://10.0.0.1/",
      "http://172.16.0.1/",
      "http://192.168.1.1/",
      "http://100.64.0.1/"
    ]

    for t <- targets do
      assert {:error, "denied"} = PyNet.fetch(:get, t), "RED-TEAM bypass not blocked through guest: #{t}"
    end
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

  @tag :netdeps
  @tag timeout: 120_000
  test "URLLIB ADAPTER — UNMODIFIED urllib.request.urlopen code runs brokered (no source changes)" do
    # a plain Python program using the stdlib urllib — no awareness of the broker — works because the adapter
    # reroutes urlopen through the file protocol.
    script = ~S"""
    import urllib.request
    r = urllib.request.urlopen("http://example.com/")
    body = r.read()
    print("CODE", r.status)
    print("BYTES", len(body))
    print("HASTITLE", "Example Domain" in body.decode("utf-8", "replace"))
    """

    assert {:ok, out} = PyNet.run_python_urllib(script)
    assert out =~ "CODE 200"
    assert out =~ "HASTITLE True"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "REQUESTS SHIM — `import requests; requests.get(...)` works brokered (no requests package needed)" do
    script = ~S"""
    import requests
    r = requests.get("http://example.com/")
    print("CODE", r.status_code)
    print("HASTITLE", "Example Domain" in r.text)
    """

    assert {:ok, out} = PyNet.run_python_urllib(script)
    assert out =~ "CODE 200"
    assert out =~ "HASTITLE True"
  end

  test "REQUESTS SHIM — SSRF enforced (requests.get to metadata is denied)" do
    script = ~S"""
    import requests, urllib.error
    try:
        requests.get("http://169.254.169.254/latest/")
        print("REACHED")
    except urllib.error.URLError as e:
        print("BLOCKED", e.reason)
    """

    assert {:ok, out} = PyNet.run_python_urllib(script)
    assert out =~ "BLOCKED"
    refute out =~ "REACHED"
  end

  test "URLLIB ADAPTER — SSRF still enforced through the adapter (urlopen to metadata raises)" do
    # even the convenient urlopen path can't reach internal targets — the host denies, the adapter raises.
    script = ~S"""
    import urllib.request, urllib.error
    try:
        urllib.request.urlopen("http://169.254.169.254/latest/")
        print("REACHED")
    except urllib.error.URLError as e:
        print("BLOCKED", e.reason)
    """

    assert {:ok, out} = PyNet.run_python_urllib(script)
    assert out =~ "BLOCKED"
    refute out =~ "REACHED"
  end
end
