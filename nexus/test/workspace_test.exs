defmodule Nexus.WorkspaceTest do
  use ExUnit.Case, async: false

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wbdata_#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)

    on_exit(fn ->
      File.rm_rf!(data)
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
    end)

    {:ok, data: data}
  end

  test "backup bundles a workspace to cold storage; restore reconstructs it with history" do
    ws = Path.join(System.tmp_dir!(), "ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)

    File.write!(Path.join(ws, "a.work"), "# Page\n")
    assert {:ok, _sha} = Nexus.Git.commit(ws, "add a.work")

    assert {:ok, bytes} = Nexus.Workspace.backup(ws, "ws1/backup.bundle")
    assert bytes > 0

    dest = Path.join(System.tmp_dir!(), "wsr_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)
    assert Nexus.Workspace.restore("ws1/backup.bundle", dest) == :ok

    # the restored repo has the file and the commit
    assert File.read!(Path.join(dest, "a.work")) == "# Page\n"
    assert [%{message: "add a.work"} | _] = Nexus.Git.log(dest)
  end
end
