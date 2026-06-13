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

  test "FORK-BOMB DEPTH — a :pynet orchestrator that execs ITSELF is bounded by @max_depth (not infinite)" do
    # the tool reads its depth from argv and re-execs itself one deeper. ExecBroker's @max_depth (8) must stop
    # the chain — proving the depth bound spans the PyNet file-exec hop (else this recurses until OOM/timeout).
    recur = ~S"""
    import subprocess, sys
    depth = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    print("DEPTH", depth)
    if depth < 50:
        cp = subprocess.run(["recurse-self", str(depth + 1)], text=True)
        sys.stdout.write(cp.stdout)  # surface the nested chain so the bound is observable
        print("CHILD_RC", depth, cp.returncode)
    """

    :ok =
      Workbooks.CommandRegistry.register_pynet("recurse-self", recur, :argv, %{
        exec_allow: true,
        commands: ["recurse-self"]
      })

    # TERMINATES (the bound holds), the chain reaches the @max_depth frontier and is then DENIED — the recursion
    # is cut off well before the script's own limit of 50.
    assert {:ok, out, 0} = Workbooks.CommandRegistry.run_status("recurse-self", "", [])
    assert out =~ "DEPTH 0"
    # the depth bound stopped it: a deep frame's child exec was denied (rc 1), and the script's limit (50) and
    # even DEPTH 20 were never reached.
    assert out =~ ~r/CHILD_RC \d+ 1/, "expected a depth-bound denial (CHILD_RC N 1) in:\n#{out}"
    refute out =~ "DEPTH 20"
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
