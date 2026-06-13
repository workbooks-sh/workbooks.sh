defmodule Workbooks.BrokeredToolsTest do
  @moduledoc """
  Phase-4 reclaim: the curl-class `http` client is a REAL, registered, first-class command that delivers
  HTTP-client capability through the mediated brokers (SSRF-safe). This is the "wire a real HTTP client" keystone
  — the sandbox now ships a working curl/httpie-class tool, no per-binary port, all egress host-mediated.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{BrokeredTools, CommandRegistry}

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    BrokeredTools.register_all()
    :ok
  end

  test "the `http` command is registered as a first-class command" do
    assert "http" in CommandRegistry.list()
  end

  test "SSRF — `http` to an internal/metadata target is denied (non-zero exit, no body leak)" do
    assert {:ok, out, status} =
             CommandRegistry.run_status("http", "", ["http://169.254.169.254/latest/meta-data/"])

    assert status != 0
    refute out =~ "ami-id"
    refute out =~ "instance-id"
  end

  test "usage — no URL prints usage and exits non-zero" do
    assert {:ok, _out, status} = CommandRegistry.run_status("http", "", [])
    assert status != 0
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "LIVE — `http URL` fetches a public page through the broker (curl-class GET)" do
    assert {:ok, out, 0} = CommandRegistry.run_status("http", "", ["http://example.com/"])
    assert out =~ "Example Domain"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "LIVE — explicit method + the exit code reflects the HTTP status (>=400 -> non-zero)" do
    # example.com/nope is a 404 -> the client exits 1 (status-aware, like curl --fail-ish)
    assert {:ok, _out, status} = CommandRegistry.run_status("http", "", ["GET", "http://example.com/nope-404"])
    assert status == 1
  end

  test "pip-fetch is registered + prints usage on no arg" do
    assert "pip-fetch" in CommandRegistry.list()
    assert {:ok, _out, status} = CommandRegistry.run_status("pip-fetch", "", [])
    assert status != 0
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "LIVE — pip-fetch retrieves PyPI metadata + dist URLs over HTTPS through the broker (pip's network half)" do
    # the network-as-purpose blocker for pip is reclaimed: fetch a package's metadata + wheel/sdist URLs from
    # the PyPI JSON API over the FULL brokered HTTPS stack (NetGuard pin+verify_peer -> requests shim).
    assert {:ok, out, 0} = CommandRegistry.run_status("pip-fetch", "", ["six"])
    assert out =~ "name: six"
    assert out =~ "version:"
    assert out =~ "file:" and out =~ "pythonhosted.org"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "pip-fetch — a nonexistent package exits non-zero (404 handled)" do
    assert {:ok, _out, status} =
             CommandRegistry.run_status("pip-fetch", "", ["wb-nonexistent-pkg-xyzzy-9920"])

    assert status != 0
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "LIVE — npm-fetch retrieves npm registry metadata + tarball URL over HTTPS (npm/pnpm/yarn network half)" do
    assert {:ok, out, 0} = CommandRegistry.run_status("npm-fetch", "", ["left-pad"])
    assert out =~ "name: left-pad"
    assert out =~ "version:"
    assert out =~ "tarball:" and out =~ "registry.npmjs.org"
  end

  test "tcp-send is registered + prints usage on missing args" do
    assert "tcp-send" in CommandRegistry.list()
    assert {:ok, _out, status} = CommandRegistry.run_status("tcp-send", "", ["example.com"])
    assert status != 0
  end

  test "RAW-TCP SSRF — tcp-send to an internal host is denied (host-pinned, before connect)" do
    # the host resolves + refuses internal/non-routable before opening the socket; the guest never connects.
    assert {:ok, _out, status} = CommandRegistry.run_status("tcp-send", "x", ["127.0.0.1", "80"])
    assert status != 0
  end

  test "RAW-TCP DEFAULT-DENY — wb_tcp is refused unless the tool's registration granted :tcp_allow" do
    # same tool body, registered WITHOUT :tcp_allow -> the brokered tcp is denied (raw sockets aren't ambient).
    script = ~S"""
    try:
        wb_tcp("example.com", 80, b"x")
        print("REACHED")
    except OSError as e:
        print("BLOCKED", e)
    """

    assert {:ok, out, _s} = Workbooks.PyNet.run_tool(script, "", [])
    assert out =~ "BLOCKED" and out =~ "tcp_denied"
    refute out =~ "REACHED"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "LIVE — tcp-send does a raw HTTP/1 request to example.com:80 through the broker (DB-client class)" do
    req = "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"
    assert {:ok, out, 0} = CommandRegistry.run_status("tcp-send", req, ["example.com", "80"])
    assert out =~ "HTTP/1"
    assert out =~ "Example Domain"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "SCOPE — a per-instance allow-list can confine the http client (off-list host denied)" do
    :ok = BrokeredTools.register_http(%{allow: ["example.com"]})
    # on-list works
    assert {:ok, out, 0} = CommandRegistry.run_status("http", "", ["http://example.com/"])
    assert out =~ "Example Domain"
    # off-list public host denied (allow-list, pre-DNS)
    assert {:ok, _o, s} = CommandRegistry.run_status("http", "", ["http://8.8.8.8/"])
    assert s != 0
    # restore the unscoped default for other tests
    BrokeredTools.register_http()
  end
end
