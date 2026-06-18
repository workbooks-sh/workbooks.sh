defmodule WorkCLI.DevTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    WorkCore.Log.configure(color: false, json: false)
    dir = Path.join(System.tmp_dir!(), "dev_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.work"), "# A\n\nserver elixir :a do\n  def x, do: 1\nend\n")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "weave_once writes the workbook and reports", %{dir: dir} do
    out = Path.join(dir, "out.html")
    log = capture_io(fn -> assert {:ok, ^out} = WorkCLI.Dev.weave_once(dir, out) end)
    assert log =~ "wove"
    assert File.read!(out) =~ "work-component"
  end

  test "changed/2 detects added, removed, and modified files", %{dir: dir} do
    s1 = WorkCLI.Dev.snapshot(dir)
    assert WorkCLI.Dev.changed(s1, s1) == []

    # add a file
    b = Path.join(dir, "b.work")
    File.write!(b, "# B\n")
    s2 = WorkCLI.Dev.snapshot(dir)
    assert b in WorkCLI.Dev.changed(s1, s2)

    # modify (force a different mtime)
    s_mod = Map.put(s2, b, s2[b] + 1)
    assert b in WorkCLI.Dev.changed(s2, s_mod)

    # remove
    File.rm!(b)
    s3 = WorkCLI.Dev.snapshot(dir)
    assert b in WorkCLI.Dev.changed(s2, s3)
  end
end
