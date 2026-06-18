defmodule Nexus.SchemaTest do
  use ExUnit.Case
  alias Nexus.{Graph, Schema, Resource, Store}

  @tmp Path.join(System.tmp_dir!(), "nx_schema_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    File.write!(Path.join(@tmp, "order.work"), """
    # Order

    ```elixir
    resource :order do
      id :text
      total :int
    end
    ```
    """)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  defp compiled do
    [node] =
      Path.join(@tmp, "order.work") |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code))

    Resource.compile(node)
  end

  test "introspects the live store: backend, storage mode, rows, declared shape" do
    mod = compiled()
    {:ok, _} = Store.create(mod, %{id: "a", total: 5})

    s = Schema.of(mod)
    assert s.backend == Nexus.Store.Ets
    assert s.storage == :memory
    assert s.rows == 1
    assert Enum.any?(s.declared, fn {n, _} -> n == :total end)
    # ETS has no field-level columns to drift against
    assert s.drift == nil
  end

  test "overlay joins the data facet onto the graph node (declared module preserved)" do
    mod = compiled()
    {:ok, _} = Store.create(mod, %{id: "b", total: 9})

    g = Graph.build_dir(@tmp)
    ov = Schema.overlay([{"order", mod}])
    lensed = Graph.with_overlay(g, ov)

    data = lensed.nodes["order"].facets.data
    assert data.module == Order            # declared (from the pure build) preserved
    assert data.backend == Nexus.Store.Ets # reality merged in
    assert data.rows == 1
    assert data.storage == :memory

    # pure graph untouched by the lens
    assert g.nodes["order"].facets.data == %{module: Order}
  end

  test "columnar drift: declared field absent from the table is flagged" do
    declared = [{:id, {:scalar, :text}}, {:total, {:scalar, :int}}, {:notes, {:scalar, :text}}]
    columns = ["id", "total", "legacy_col"]
    d = Schema.diff(declared, columns)

    refute d.ok?
    assert "notes" in d.missing      # declared, no column
    assert "legacy_col" in d.extra   # column, undeclared
  end

  # the exact contract the Postgres/Neon backend fulfils: a columnar adapter that
  # exposes real columns via columns/2. Proves Schema reads them + computes drift.
  defmodule FakeColumnar do
    @behaviour Nexus.Store
    def create(_m, _a, _t), do: {:ok, %{}}
    def all(_m, _t), do: []
    def count(_m, _t), do: 3
    def clear(_m, _t), do: :ok
    # live table is missing `total` and has an undeclared `legacy`
    def columns(_m, _t), do: ["id", "legacy"]
  end

  test "columnar backend (Postgres-shaped): real columns introspected + drift computed" do
    mod = compiled()
    prev = Application.fetch_env(:nexus, :store_adapter)
    Application.put_env(:nexus, :store_adapter, FakeColumnar)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:nexus, :store_adapter, v)
        :error -> Application.delete_env(:nexus, :store_adapter)
      end
    end)

    s = Schema.of(mod)
    assert s.storage == :columnar
    assert s.columns == ["id", "legacy"]
    assert s.rows == 3
    refute s.drift.ok?
    assert "total" in s.drift.missing   # declared field, no column → drift
    assert "legacy" in s.drift.extra    # undeclared column → drift
  end
end
