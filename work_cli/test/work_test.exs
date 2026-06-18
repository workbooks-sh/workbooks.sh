defmodule WorkCLI.WorkTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    WorkCore.Log.configure(color: false, json: false)
    dir = Path.join(System.tmp_dir!(), "worktest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.work"), """
    # Pipeline

    server elixir :pipeline do
      def run(x), do: WorkCore.Graph.build_dir(x)
    end

    See [[helper]] for the support unit.
    """)

    File.write!(Path.join(dir, "b.work"), """
    # Helper

    server elixir :helper do
      def help, do: :ok
    end
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "check resolves references across the tree", %{dir: dir} do
    out = capture_io(fn -> assert WorkCLI.Work.check(dir) == :ok end)
    assert out =~ "✓"
    assert out =~ "units"
    assert out =~ "references resolve"
  end

  test "check fails on a dangling reference", %{dir: dir} do
    File.write!(Path.join(dir, "c.work"), "# Bad\n\nSee [[nonexistent_unit]].\n")
    out = capture_io(fn -> assert {:error, :faults} = WorkCLI.Work.check(dir) end)
    assert out =~ "✗"
  end

  test "structure lists units", %{dir: dir} do
    out = capture_io(fn -> assert WorkCLI.Work.structure(dir) == :ok end)
    assert out =~ ":pipeline"
    assert out =~ ":helper"
  end

  test "near reports edges or their absence", %{dir: dir} do
    out = capture_io(fn -> assert WorkCLI.Work.near("helper", dir) == :ok end)
    assert out =~ ":helper"
  end
end
