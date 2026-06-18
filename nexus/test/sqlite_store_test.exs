defmodule Nexus.Store.SqliteTest do
  use ExUnit.Case, async: false
  alias Nexus.Store.Sqlite

  setup do
    path = Path.join(System.tmp_dir!(), "nxsq_#{System.unique_integer([:positive])}.db")
    Application.put_env(:nexus, :sqlite_path, path)

    mod =
      "resource Account do\n  name :text\n  status :new | :won\nend\n"
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))
      |> Nexus.Resource.compile()

    Sqlite.clear(mod, "default")
    on_exit(fn -> File.rm(path) end)
    {:ok, mod: mod}
  end

  test "durable CRUD via the Sqlite adapter", %{mod: mod} do
    assert {:ok, %{name: "A"}} = Sqlite.create(mod, %{name: "A", status: :new}, "default")
    assert Sqlite.count(mod, "default") == 1
  end

  test "durable across a fresh connection; enum atoms round-trip", %{mod: mod} do
    Sqlite.create(mod, %{name: "Persisted", status: :won}, "default")
    assert ["Persisted"] == Enum.map(Sqlite.all(mod, "default"), & &1.name)
    assert [:won] == Enum.map(Sqlite.all(mod, "default"), & &1.status)
  end

  test "validation enforced — bad enum rejected, nothing stored", %{mod: mod} do
    assert {:error, {:bad_enum, :status, :nope, _}} = Sqlite.create(mod, %{status: :nope}, "default")
    assert Sqlite.count(mod, "default") == 0
  end

  test "TENANT ISOLATION — a tenant cannot read or count another tenant's rows", %{mod: mod} do
    Sqlite.create(mod, %{name: "Alice"}, "t1")
    Sqlite.create(mod, %{name: "Bob"}, "t2")

    assert ["Alice"] == Enum.map(Sqlite.all(mod, "t1"), & &1.name)
    assert ["Bob"] == Enum.map(Sqlite.all(mod, "t2"), & &1.name)
    assert Sqlite.all(mod, "t3") == []
    assert Sqlite.count(mod, "t1") == 1

    Sqlite.clear(mod, "t1")
    assert Sqlite.all(mod, "t1") == []
    assert ["Bob"] == Enum.map(Sqlite.all(mod, "t2"), & &1.name)
  end
end
