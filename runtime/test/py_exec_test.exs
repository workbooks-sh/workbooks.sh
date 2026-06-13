defmodule Workbooks.PyExecTest do
  @moduledoc """
  Proves the exec->CommandRegistry dispatch stone applied to the Python lane: a wasip1 CPython (no fork/exec)
  orchestrates BROKERED commands via a subprocess shim over the PyNet file protocol. The exec runs through
  ExecBroker — default-deny, REGISTERED-commands-only, no shell/injection, output-capped — so a Python tool can
  drive brokered wasm commands (the build-driver/pipx class) but can never escape to a host shell or run an
  arbitrary binary.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PyNet

  setup_all do
    if "python" not in Workbooks.CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok
  end

  test "DEFAULT-DENY — subprocess.run is refused unless the host grants :exec_allow" do
    # the shim is always present, but exec is OFF by default — a net tool doesn't get exec for free.
    script = ~S"""
    import subprocess
    cp = subprocess.run(["jq", "."], input='{"a":1}', text=True)
    print("RC", cp.returncode)
    print("OUT", cp.stdout.strip())
    """

    assert {:ok, out, _status} = PyNet.run_tool(script, "", [])
    assert out =~ "RC 1"
    refute out =~ ~s("a")
  end

  test "GRANTED — subprocess.run dispatches to a brokered REGISTERED command (jq runs, output returned)" do
    # exec granted -> the call routes to ExecBroker -> CommandRegistry.run("jq", ...). Proof of dispatch: the
    # command RAN (returncode 0) and its real stdout came back through the file protocol (non-empty). The exact
    # bytes depend on jq's :stdin1 arg-wrapping; the point is a brokered registered command executed.
    script = ~S"""
    import subprocess
    cp = subprocess.run(["jq", "."], input='{"a":1}', text=True)
    print("RC", cp.returncode)
    print("NONEMPTY", len(cp.stdout) > 0)
    """

    assert {:ok, out, _status} = PyNet.run_tool(script, "", [], exec_allow: true)
    assert out =~ "RC 0"
    assert out =~ "NONEMPTY True"
  end

  test "COMMAND-SCOPE — :commands confines WHICH commands the guest may run (jq denied when only grep granted)" do
    script = ~S"""
    import subprocess
    cp = subprocess.run(["jq", "."], input='{"a":1}', text=True)
    print("RC", cp.returncode)
    """

    # exec granted, but the scope excludes jq -> denied (command_not_granted), the guest sees a non-zero rc.
    assert {:ok, out, _status} = PyNet.run_tool(script, "", [], exec_allow: true, commands: ["grep"])
    assert out =~ "RC 1"
  end

  test "NO SHELL ESCAPE — an unregistered/arbitrary binary name is refused even when exec is granted" do
    script = ~S"""
    import subprocess
    cp = subprocess.run(["/bin/sh", "-c", "echo pwned"], text=True)
    print("RC", cp.returncode)
    print("OUT", repr(cp.stdout))
    """

    assert {:ok, out, _status} = PyNet.run_tool(script, "", [], exec_allow: true)
    assert out =~ "RC 1"
    refute out =~ "pwned"
  end
end
