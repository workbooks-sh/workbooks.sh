defmodule Nexus.StorePageTest do
  @moduledoc "Pagination/filter/sort contract for Nexus.Store.page across backends (wb-kssk)."
  use ExUnit.Case, async: false
  alias Nexus.Store

  setup do
    mod =
      "resource Widget do\n  name :text\n  rank :int\nend\n"
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))
      |> Nexus.Resource.compile()

    Store.clear(mod)
    Store.clear(mod, "other")
    {:ok, mod: mod}
  end

  defp seed(mod, n, tenant \\ "default") do
    for i <- 1..n, do: {:ok, _} = Store.create(mod, %{name: "w#{i}", rank: i}, tenant)
    :ok
  end

  describe "ETS backend (default adapter)" do
    test "offset/limit page with correct total", %{mod: mod} do
      seed(mod, 25)
      {rows, total} = Store.page(mod, "default", offset: 10, limit: 5)
      assert total == 25
      assert length(rows) == 5
      assert Enum.map(rows, & &1.rank) == [11, 12, 13, 14, 15]
    end

    test "limit is clamped to 1..500 and offset floored at 0", %{mod: mod} do
      seed(mod, 3)
      {rows, _} = Store.page(mod, "default", offset: -9, limit: 9999)
      assert length(rows) == 3
      {rows2, _} = Store.page(mod, "default", limit: 0)
      assert length(rows2) == 1
    end

    test "q filters across decoded fields; total reflects matches not page", %{mod: mod} do
      seed(mod, 12)
      # "w1" matches w1, w10, w11, w12
      {rows, total} = Store.page(mod, "default", q: "w1", limit: 2)
      assert total == 4
      assert length(rows) == 2
      assert Enum.all?(rows, &String.contains?(&1.name, "w1"))
    end

    test "field sort asc/desc", %{mod: mod} do
      seed(mod, 5)
      {asc, _} = Store.page(mod, "default", sort: {"rank", :asc}, limit: 100)
      {desc, _} = Store.page(mod, "default", sort: {"rank", :desc}, limit: 100)
      assert Enum.map(asc, & &1.rank) == [1, 2, 3, 4, 5]
      assert Enum.map(desc, & &1.rank) == [5, 4, 3, 2, 1]
    end

    test "unknown sort field degrades to insertion order, never crashes", %{mod: mod} do
      seed(mod, 3)
      {rows, total} = Store.page(mod, "default", sort: {"nonexistent_field_xyz", :asc})
      assert total == 3
      assert Enum.map(rows, & &1.rank) == [1, 2, 3]
    end

    test "empty resource yields {[], 0}", %{mod: mod} do
      assert {[], 0} = Store.page(mod, "default", limit: 50)
    end

    test "nil field values trail in BOTH sort directions (slicer)", %{mod: mod} do
      rows = [struct(mod, rank: 5), struct(mod, rank: nil), struct(mod, rank: 2)]
      {asc, 3} = Nexus.Store.Page.apply(rows, sort: {"rank", :asc}, limit: 100)
      {desc, 3} = Nexus.Store.Page.apply(rows, sort: {"rank", :desc}, limit: 100)
      assert Enum.map(asc, & &1.rank) == [2, 5, nil]
      assert Enum.map(desc, & &1.rank) == [5, 2, nil]
    end

    test "ADVERSARIAL: paging tenant A never leaks tenant B's rows", %{mod: mod} do
      seed(mod, 5, "default")
      seed(mod, 5, "other")
      {rows, total} = Store.page(mod, "other", limit: 100, q: "w")
      assert total == 5
      assert length(rows) == 5
    end
  end

  describe "SQLite backend (native LIMIT/OFFSET)" do
    setup do
      path = Path.join(System.tmp_dir!(), "nxpage_#{System.unique_integer([:positive])}.db")
      prev_adapter = Application.get_env(:nexus, :store_adapter)
      Application.put_env(:nexus, :store_adapter, Nexus.Store.Sqlite)
      Application.put_env(:nexus, :sqlite_path, path)

      on_exit(fn ->
        if prev_adapter,
          do: Application.put_env(:nexus, :store_adapter, prev_adapter),
          else: Application.delete_env(:nexus, :store_adapter)

        Application.delete_env(:nexus, :sqlite_path)
        File.rm(path)
      end)

      :ok
    end

    test "native page returns the correct slice + COUNT(*) total", %{mod: mod} do
      assert Store.adapter() == Nexus.Store.Sqlite
      seed(mod, 100)
      {rows, total} = Store.page(mod, "default", offset: 95, limit: 50)
      assert total == 100
      assert length(rows) == 5
      assert Enum.map(rows, & &1.rank) == [96, 97, 98, 99, 100]
    end

    test "filter falls back to slicer but stays correct + tenant-scoped", %{mod: mod} do
      seed(mod, 20, "default")
      seed(mod, 3, "other")
      {rows, total} = Store.page(mod, "default", q: "w2")
      # w2, w20 → 2 matches in "default"
      assert total == 2
      assert Enum.all?(rows, &String.contains?(&1.name, "w2"))
    end
  end
end
