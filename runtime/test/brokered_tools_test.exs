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
