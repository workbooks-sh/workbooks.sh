defmodule Workbooks.RunCommandTelemetryTest do
  use ExUnit.Case, async: true

  alias Workbooks.Instance.Imports
  alias Workbooks.Workflow.Telemetry

  test "run-command Dock call emits a workdir-scoped step that summary/1 counts" do
    workdir = Path.join(System.tmp_dir!(), "rc_telemetry_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf(workdir) end)

    # No VFS needed for the commands cap; pass nil for the conn.
    info = %{id: "t1", tenant: "dev", profile: :minimal}
    imports = Imports.for_caps(["commands"], nil, info, workdir: workdir)

    {:fn, run_command} = Map.fetch!(imports, "run-command")

    # Exercise the real Dock closure against a real (Javy-built) builtin.
    out = run_command.("upper", "hi there", [])
    assert out == "HI THERE"

    # The step line landed in the workdir's always-on telemetry log.
    body = File.read!(Path.join(workdir, "_steps.jsonl"))
    [line] = String.split(body, "\n", trim: true)
    step = Jason.decode!(line)

    assert step["tool"] == "command:upper"
    assert step["exit_code"] == 0
    assert step["step"] == 0
    assert is_integer(step["dur_ms"])
    assert is_integer(step["ts"])

    # And summary/1 counts it like any other tool call.
    summary = Telemetry.summary(workdir)
    assert summary.tool_calls == 1
    assert summary.errors == []
    assert [%{"tool" => "command:upper"}] = summary.recent

    # A second call increments the step counter (no overwrite).
    run_command.("upper", "again", [])
    assert Telemetry.summary(workdir).tool_calls == 2
  end

  test "with no workdir the closure runs but writes no step" do
    info = %{id: "t2", tenant: "dev", profile: :minimal}
    imports = Imports.for_caps(["commands"], nil, info, [])
    {:fn, run_command} = Map.fetch!(imports, "run-command")

    assert run_command.("upper", "ok", []) == "OK"
  end
end
