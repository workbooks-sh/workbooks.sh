defmodule Workbooks.PyNetCommandTest do
  @moduledoc """
  Proves the reachable→LIVE mechanism for the Python net-tool class: a `:pynet` command runs a Python network
  CLI under CPython with the brokered urllib/requests transport — a first-class registry command, no wasip2
  build, every request SSRF-mediated by the host. This is the per-tool live path the reachable httpie/pip/curl
  class was waiting on (their runtime network blocker was already removed; this is the build-free route).
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  @fetch_tool ~S"""
  import sys, urllib.request, urllib.error
  if len(sys.argv) < 2:
      print("usage: fetch URL", file=sys.stderr); sys.exit(2)
  try:
      r = urllib.request.urlopen(sys.argv[1])
      sys.stdout.write("HTTP %s\n" % r.status)
      body = r.read()
      sys.stdout.write("BYTES %d\n" % len(body))
  except urllib.error.URLError as e:
      print("ERR %s" % e.reason, file=sys.stderr); sys.exit(1)
  """

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok = CommandRegistry.register_pynet("brokered-fetch", @fetch_tool, :argv, %{})
    :ok
  end

  test "a :pynet command is registered + listed as a first-class command" do
    assert "brokered-fetch" in CommandRegistry.list()
  end

  test "SSRF — the brokered-fetch command CANNOT reach an internal target (host-mediated)" do
    # the tool calls urlopen(metadata); the host denies; the tool exits non-zero with no body. The guest never
    # reaches the internal target no matter what URL it's handed.
    assert {:ok, out, status} =
             CommandRegistry.run_status("brokered-fetch", "", ["http://169.254.169.254/latest/meta-data/"])

    assert status != 0
    refute out =~ "HTTP 200"
    refute out =~ "BYTES"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "LIVE — the brokered-fetch command retrieves a real public URL (reachable→live, no wasip2 build)" do
    assert {:ok, out, 0} = CommandRegistry.run_status("brokered-fetch", "", ["http://example.com/"])
    assert out =~ "HTTP 200"
    assert out =~ "BYTES"
  end

  @orch_tool ~S"""
  import subprocess
  cp = subprocess.run(["jq", "."], input='{"x":1}', text=True)
  print("RC", cp.returncode)
  print("LEN", len(cp.stdout))
  """

  test "ORCHESTRATOR — a registered :pynet command drives a brokered command ONLY when granted :exec_allow" do
    # granted: the registration carries :exec_allow + a :commands scope, so the Python tool can run brokered jq.
    :ok = CommandRegistry.register_pynet("orch-yes", @orch_tool, :argv, %{exec_allow: true, commands: ["jq"]})
    assert {:ok, out, 0} = CommandRegistry.run_status("orch-yes", "", [])
    assert out =~ "RC 0"
    assert out =~ "LEN" and not (out =~ "LEN 0")

    # not granted: same tool, no :exec_allow -> the brokered exec is default-denied (the guest sees rc 1).
    :ok = CommandRegistry.register_pynet("orch-no", @orch_tool, :argv, %{})
    assert {:ok, out2, 0} = CommandRegistry.run_status("orch-no", "", [])
    assert out2 =~ "RC 1"
  end

  test "ORCHESTRATOR SCOPE — :commands confines which brokered commands a registered tool may run" do
    # exec granted but the scope excludes jq -> the tool's jq call is denied (command_not_granted), rc 1.
    :ok = CommandRegistry.register_pynet("orch-scoped", @orch_tool, :argv, %{exec_allow: true, commands: ["grep"]})
    assert {:ok, out, 0} = CommandRegistry.run_status("orch-scoped", "", [])
    assert out =~ "RC 1"
  end

  @tag :netdeps
  @tag timeout: 120_000
  test "SCOPE — a per-instance allow-list confines the command (default-deny for off-list hosts)" do
    :ok = CommandRegistry.register_pynet("scoped-fetch", @fetch_tool, :argv, %{allow: ["example.com"]})
    # on-list host works
    assert {:ok, out, 0} = CommandRegistry.run_status("scoped-fetch", "", ["http://example.com/"])
    assert out =~ "HTTP 200"
    # off-list public host is denied even though it passes the SSRF floor
    assert {:ok, _out2, s2} = CommandRegistry.run_status("scoped-fetch", "", ["http://8.8.8.8/"])
    assert s2 != 0
  end
end
