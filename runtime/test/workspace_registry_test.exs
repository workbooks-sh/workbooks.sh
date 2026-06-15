defmodule Workbooks.WorkspaceRegistryTest do
  use ExUnit.Case, async: false

  alias Workbooks.WorkspaceRegistry, as: WR

  setup do
    prev_data = System.get_env("WB_DATA")
    prev_url = System.get_env("WB_DATABASE_URL")
    System.delete_env("WB_DATABASE_URL")
    dir = Path.join(System.tmp_dir!(), "ws-test-#{System.unique_integer([:positive])}")
    System.put_env("WB_DATA", dir)

    on_exit(fn ->
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_url, do: System.put_env("WB_DATABASE_URL", prev_url)
      File.rm_rf(dir)
    end)

    {:ok, h: WR.open()}
  end

  test "create is free + readable back, scoped to the org", %{h: h} do
    assert {:ok, ws} = WR.create("org-a", "Marketing", [], h)
    assert ws.name == "Marketing"
    assert String.starts_with?(ws.id, "ws-")
    assert [%{name: "Marketing"}] = WR.list("org-a", h)
  end

  test "two orgs can both have a 'Marketing' workspace (no PK collision)", %{h: h} do
    assert {:ok, a} = WR.create("org-a", "Marketing", [], h)
    assert {:ok, b} = WR.create("org-b", "Marketing", [], h)
    assert a.id != b.id
    assert [%{name: "Marketing"}] = WR.list("org-a", h)
    assert [%{name: "Marketing"}] = WR.list("org-b", h)
  end

  test "org A never sees org B's workspaces", %{h: h} do
    {:ok, _} = WR.create("org-a", "Acme", [], h)
    {:ok, b} = WR.create("org-b", "Beta", [], h)

    assert WR.list("org-a", h) |> Enum.map(& &1.name) == ["Acme"]
    assert {:error, :not_found} = WR.get(b.id, "org-a", h)
  end

  test "rename + delete are ownership-gated", %{h: h} do
    {:ok, ws} = WR.create("org-a", "Old", [], h)
    assert {:error, :not_found} = WR.rename(ws.id, "org-b", "Hijack", h)
    assert {:ok, %{name: "New"}} = WR.rename(ws.id, "org-a", "New", h)
    assert {:error, :not_found} = WR.delete(ws.id, "org-b", h)
    assert :ok = WR.delete(ws.id, "org-a", h)
    assert WR.list("org-a", h) == []
  end

  test "ensure creates a default only when none exist", %{h: h} do
    assert [%{name: "Acme"}] = WR.ensure("org-a", "Acme", h)
    # second ensure returns the existing one, does NOT create a duplicate
    assert [%{name: "Acme"}] = WR.ensure("org-a", "Acme", h)
    assert length(WR.list("org-a", h)) == 1
  end

  test "fails closed on blank org + empty name", %{h: h} do
    assert {:error, :no_org} = WR.create("", "X", [], h)
    assert {:error, :invalid_name} = WR.create("org-a", "   ", [], h)
    assert WR.list("", h) == []
  end

  test "nexus_id pins compute (default nil = org primary)", %{h: h} do
    {:ok, free} = WR.create("org-a", "Shared", [], h)
    {:ok, iso} = WR.create("org-a", "Isolated", [nexus_id: "nx-123"], h)
    assert free.nexus_id == nil
    assert iso.nexus_id == "nx-123"
  end
end
