defmodule Nexus.WorkspacesTest do
  @moduledoc "The workspace-tree ops a general agent + snapshot-isolated evals ride on (no CP, no jj needed)."
  use ExUnit.Case, async: false
  alias Nexus.Workspaces

  setup do
    prev = System.get_env("WB_DATA")
    root = Path.join(System.tmp_dir!(), "wsroot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.put_env("WB_DATA", root)

    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp mk(root, name, file \\ "a.work") do
    d = Path.join(root, name)
    File.mkdir_p!(d)
    File.write!(Path.join(d, file), "# #{name}\n")
    d
  end

  test "list/0 is just the workspace folders — never .nexus, cache, or dotfiles", %{root: root} do
    mk(root, "proj")
    File.mkdir_p!(Path.join(root, ".nexus"))
    File.mkdir_p!(Path.join(root, "cache"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    assert Workspaces.list() == ["proj"]
  end

  test "provision registers a workspace; deprovision removes it entirely", %{root: _root} do
    mk(System.get_env("WB_DATA"), "proj")
    refute Workspaces.registered?("proj")

    assert {:ok, "proj"} = Workspaces.provision("proj")
    assert Workspaces.registered?("proj")
    assert "proj" in Workspaces.list()

    assert :ok = Workspaces.deprovision("proj")
    refute Workspaces.registered?("proj")
    refute File.dir?(Workspaces.work_dir("proj"))
  end

  test "stage + sync_back turns a new top-level dir into a real workspace", %{root: root} do
    mk(root, "proj")
    Workspaces.provision("proj")
    before = Workspaces.list()

    staging = Path.join(System.tmp_dir!(), "stg_#{System.unique_integer([:positive])}")
    assert Workspaces.stage(staging) == ["proj"]
    # a general agent creates a NEW workspace dir inside its /work (the staging copy)
    mk(staging, "marketing", "README.work")

    assert Workspaces.sync_back(staging, before) == ["marketing"]
    assert Workspaces.registered?("marketing")
    assert File.exists?(Path.join(Workspaces.work_dir("marketing"), "README.work"))
    File.rm_rf!(staging)
  end

  test "snapshot + restore deletes workspaces created since the snapshot (eval rollback)", %{root: root} do
    mk(root, "proj")
    Workspaces.provision("proj")
    snap = Workspaces.snapshot()
    assert snap.names == ["proj"]

    mk(root, "marketing")
    Workspaces.provision("marketing")
    assert "marketing" in Workspaces.list()

    assert :ok = Workspaces.restore(snap)
    refute "marketing" in Workspaces.list()
    refute File.dir?(Workspaces.work_dir("marketing"))
    assert "proj" in Workspaces.list()
  end

  test "provision/deprovision refuse unsafe names (traversal, dotdirs)", %{root: _r} do
    assert {:error, :bad_name} = Workspaces.provision("../escape")
    assert {:error, :bad_name} = Workspaces.deprovision("..")
    assert {:error, :bad_name} = Workspaces.deprovision(".nexus")
  end
end
