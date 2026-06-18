defmodule Nexus.Store.SqliteTest do
  use ExUnit.Case, async: false

  setup do
    path = Path.join(System.tmp_dir!(), "nxsq_#{System.unique_integer([:positive])}.db")
    Application.put_env(:nexus, :sqlite_path, path)

    mod =
      "resource Account do\n  name :text\n  status :new | :won\nend\n"
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))
      |> Nexus.Resource.compile()

    Nexus.Store.Sqlite.clear(mod)
    on_exit(fn -> File.rm(path) end)
    {:ok, mod: mod}
  end

  test "implements the Nexus.Store behaviour — same calls as ETS", %{mod: mod} do
    assert {:ok, %{name: "A"}} = Nexus.Store.Sqlite.create(mod, %{name: "A", status: :new})
    assert Nexus.Store.Sqlite.count(mod) == 1
  end

  test "is durable — every call opens a fresh connection, so rows read from disk", %{mod: mod} do
    {:ok, _} = Nexus.Store.Sqlite.create(mod, %{name: "Persisted", status: :won})
    assert ["Persisted"] == Enum.map(Nexus.Store.Sqlite.all(mod), & &1.name)
    # enum atoms survive the serialize/deserialize round-trip through SQLite
    assert [:won] == Enum.map(Nexus.Store.Sqlite.all(mod), & &1.status)
  end

  test "enforces the same validation (bad enum rejected, nothing stored)", %{mod: mod} do
    assert {:error, {:bad_enum, :status, :nope, _}} = Nexus.Store.Sqlite.create(mod, %{status: :nope})
    assert Nexus.Store.Sqlite.count(mod) == 0
  end
end
