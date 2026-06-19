defmodule Nexus.WorkspaceTest do
  use ExUnit.Case, async: false

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wbdata_#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)
    # Recompute config (cache_cold defaults to <data_dir>/cache) under this tmp WB_DATA.
    Nexus.Config.reload(nil)

    on_exit(fn ->
      File.rm_rf!(data)
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      Nexus.Config.reload(nil)
    end)

    {:ok, data: data}
  end

  test "backup bundles a workspace to cold storage; restore reconstructs it with history" do
    ws = Path.join(System.tmp_dir!(), "ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)

    File.write!(Path.join(ws, "a.work"), "# Page\n")
    assert {:ok, _sha} = Nexus.Git.commit(ws, "add a.work")

    assert {:ok, bytes} = Nexus.Workspace.backup("tenant1", ws, "ws1/backup.bundle")
    assert bytes > 0

    # Real metering: the tenant's cold-storage footprint reflects the backup.
    assert Nexus.Storage.cold_bytes("tenant1") >= bytes
    assert Nexus.Storage.cold_bytes("other-tenant") == 0
    assert %{used_bytes: u, limit_gb: 5} = Nexus.Storage.report("tenant1", 5)
    assert u >= bytes

    dest = Path.join(System.tmp_dir!(), "wsr_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)
    assert Nexus.Workspace.restore("tenant1", "ws1/backup.bundle", dest) == :ok

    # the restored repo has the file and the commit
    assert File.read!(Path.join(dest, "a.work")) == "# Page\n"
    assert [%{message: "add a.work"} | _] = Nexus.Git.log(dest)
  end

  test "Capacity uses real measured storage bytes when provided (else showcase)" do
    nx = %{id: "nx_x", plan: "starter", state: "running"}
    real = Nexus.Capacity.report(nx, storage_bytes: 3_000_000_000)
    assert real.storage.used == 3
    # No measured bytes → falls back to the deterministic showcase (non-crashing, has a dial).
    showcase = Nexus.Capacity.report(nx)
    assert is_integer(showcase.storage.used)
  end
end
