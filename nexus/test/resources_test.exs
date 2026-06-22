defmodule Nexus.ResourcesTest do
  @moduledoc "Tree-walk resource enumeration for the Data page (wb-kssk)."
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "nxres_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "studio"))
    File.mkdir_p!(Path.join(root, "studio/sub"))

    File.write!(Path.join(root, "studio/index.work"), """
    # Studio

    resource Ticket do
      title :text
      priority :int
    end
    """)

    File.write!(Path.join(root, "studio/sub/more.work"), """
    resource Note do
      body :text
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "lists every resource in the tree with file + fields + count", %{root: root} do
    list = Nexus.Resources.list(root, "default")
    names = Enum.map(list, & &1.name) |> Enum.sort()
    assert names == ["Note", "Ticket"]

    ticket = Enum.find(list, &(&1.name == "Ticket"))
    assert ticket.file == "studio/index.work"
    assert {:title, {:scalar, :text}} in ticket.fields
    assert ticket.count == 0
    assert is_atom(ticket.module)
  end

  test "count is tenant-scoped", %{root: root} do
    [%{module: mod} | _] = Enum.filter(Nexus.Resources.list(root), &(&1.name == "Ticket"))
    Nexus.Store.clear(mod, "default")
    Nexus.Store.clear(mod, "acme")
    Nexus.Store.create(mod, %{title: "a", priority: 1}, "acme")

    assert Nexus.Resources.fetch("Ticket", root, "default") |> elem(1) |> Map.get(:count) == 0
    assert Nexus.Resources.fetch("Ticket", root, "acme") |> elem(1) |> Map.get(:count) == 1
  end

  test "fetch resolves by name; unknown name is :error", %{root: root} do
    assert {:ok, %{name: "Note"}} = Nexus.Resources.fetch("Note", root, "default")
    assert :error = Nexus.Resources.fetch("Ghost", root, "default")
  end

  test "duplicate resource name across files collapses to one entry listing both files", %{root: root} do
    File.write!(Path.join(root, "studio/dup.work"), "resource Ticket do\n  title :text\nend\n")
    list = Nexus.Resources.list(root, "default")
    tickets = Enum.filter(list, &(&1.name == "Ticket"))
    assert length(tickets) == 1
    assert "studio/dup.work" in hd(tickets).files
    assert "studio/index.work" in hd(tickets).files
  end

  test "a malformed resource block is skipped, not fatal", %{root: root} do
    File.write!(Path.join(root, "broken.work"), "resource do\n  oops\nend\n")
    # still lists the valid ones without raising
    assert length(Nexus.Resources.list(root, "default")) >= 2
  end
end
