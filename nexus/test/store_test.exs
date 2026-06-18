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

  describe "ADVERSARIAL: cross-tenant isolation (ETS)" do
    test "tenant A can never read/count/clear tenant B's rows", %{mod: mod} do
      {:ok, _} = Nexus.Store.create(mod, %{name: "A-row"}, "A")
      {:ok, _} = Nexus.Store.create(mod, %{name: "B-row"}, "B")

      assert Enum.map(Nexus.Store.all(mod, "A"), & &1.name) == ["A-row"]
      assert Nexus.Store.count(mod, "A") == 1 and Nexus.Store.count(mod, "B") == 1

      # A clears its own partition; B is untouched.
      :ok = Nexus.Store.clear(mod, "A")
      assert Nexus.Store.all(mod, "A") == []
      assert Enum.map(Nexus.Store.all(mod, "B"), & &1.name) == ["B-row"]
    end

    test "the 'default' tenant is just another partition — invisible to a real tenant", %{mod: mod} do
      {:ok, _} = Nexus.Store.create(mod, %{name: "local"})           # → "default"
      {:ok, _} = Nexus.Store.create(mod, %{name: "cloud"}, "acme")
      assert Enum.map(Nexus.Store.all(mod, "default"), & &1.name) == ["local"]
      assert Enum.map(Nexus.Store.all(mod, "acme"), & &1.name) == ["cloud"]
    end

    test "concurrent writes across tenants stay partitioned (no bleed)", %{mod: mod} do
      tasks =
        for t <- ["t1", "t2", "t3"], i <- 1..20 do
          Task.async(fn -> Nexus.Store.create(mod, %{name: "#{t}-#{i}"}, t) end)
        end

      Enum.each(tasks, &Task.await/1)

      for t <- ["t1", "t2", "t3"] do
        names = Enum.map(Nexus.Store.all(mod, t), & &1.name)
        assert length(names) == 20
        assert Enum.all?(names, &String.starts_with?(&1, t <> "-"))
      end
    end
  end
end
