defmodule Nexus.StoreTest do
  use ExUnit.Case, async: false

  setup_all do
    mod =
      "resource Lead do\n  name :text\n  revenue :int\n  status :new | :won\nend\n"
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))
      |> Nexus.Resource.compile()

    {:ok, mod: mod}
  end

  setup %{mod: mod} do
    Nexus.Store.clear(mod)
    :ok
  end

  test "a resource compiles to a typed struct carrying its field specs", %{mod: mod} do
    assert match?(%{name: "", revenue: 0, status: _}, struct(mod))
    assert {:name, {:scalar, :text}} in mod.__fields__()
    assert {:status, {:enum, [:new, :won]}} in mod.__fields__()
  end

  test "validate builds the struct and enforces enum + unknown-field constraints", %{mod: mod} do
    assert {:ok, %{name: "Acme", status: :won}} = Nexus.Resource.validate(mod, %{name: "Acme", status: :won})
    assert {:error, {:bad_enum, :status, :bogus, _}} = Nexus.Resource.validate(mod, %{status: :bogus})
    assert {:error, {:unknown_fields, [:nope]}} = Nexus.Resource.validate(mod, %{nope: 1})
  end

  test "the store persists + lists rows (ETS adapter)", %{mod: mod} do
    {:ok, _} = Nexus.Store.create(mod, %{name: "Acme", revenue: 100, status: :new})
    {:ok, _} = Nexus.Store.create(mod, %{name: "Globex", status: :won})
    assert Nexus.Store.count(mod) == 2
    assert "Acme" in Enum.map(Nexus.Store.all(mod), & &1.name)
  end

  test "the store rejects an invalid enum — no row persisted", %{mod: mod} do
    assert {:error, _} = Nexus.Store.create(mod, %{status: :nope})
    assert Nexus.Store.count(mod) == 0
  end

  test "the adapter is swappable (defaults to ETS)" do
    assert Nexus.Store.adapter() == Nexus.Store.Ets
  end
end
