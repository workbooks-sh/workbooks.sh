defmodule WorkCore.GraphTest do
  use ExUnit.Case, async: true
  alias WorkCore.Graph

  @tmp Path.join(System.tmp_dir!(), "wc_graph_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  defp write(name, body), do: File.write!(Path.join(@tmp, name), body)

  test "node carries identity + per-layer facets" do
    write("orders.work", """
    # Orders

    ```elixir
    resource :order do
      defstruct id: "", total: 0
    end
    ```
    """)

    g = Graph.build_dir(@tmp)
    node = g.nodes["order"]

    # canonical identity (§1) projections all present and consistent
    assert node.uid.key == "order"
    assert node.uid.wit == "order"
    assert node.uid.package == "work:order"
    assert node.uid.module == Order

    # per-layer facets
    assert %{source: source, interface: _iface, artifact: nil, data: data} = node.facets
    assert source.lang == "elixir"
    assert source.kind == "resource"
    assert data.module == Order

    # back-compat top-level fields preserved
    assert node.id == "order"
    assert is_list(node.exports)
  end

  test "edges are typed with layer + scope; host-cap grants become :host_cap edges" do
    write("svc.work", """
    # Service

    ```elixir
    server :svc, grant: [net: "api.example.com"] do
      def go, do: :ok
    end
    ```
    """)

    g = Graph.build_dir(@tmp)
    cap_edges = Enum.filter(g.edges, &(&1.scope == :host_cap))

    assert Enum.any?(cap_edges, &(&1.to == "net"))
    cap = Enum.find(cap_edges, &(&1.to == "net"))
    assert cap.layer == :interface
    assert cap.type == :import
    # every edge now carries the typed-edge fields
    assert Enum.all?(g.edges, &(Map.has_key?(&1, :layer) and Map.has_key?(&1, :scope)))
  end

  test "shared_types builds a cross-file registry; world/2 resolves a record param (no string degrade)" do
    write("types.work", """
    # Types

    ```elixir
    defmodule Lead do
      defstruct name: "", score: 0
    end
    ```
    """)

    write("enrich.work", """
    # Enrich

    ```elixir
    server :enrich do
      def run(%Lead{} = lead), do: lead
    end
    ```
    """)

    g = WorkCore.Graph.build_dir(@tmp)

    # the unified type registry sees the cross-file record
    assert Map.has_key?(g.types, "lead")
    {iface, names} = WorkCore.Graph.shared_types(g)
    assert "lead" in names
    assert iface =~ "record lead"

    # the per-unit world resolved against the registry types the param as the
    # record (NOT string) and is self-contained valid WIT
    enrich = Path.join(@tmp, "enrich.work") |> File.read!() |> WorkCore.Literate.parse() |> Enum.find(&(&1[:name] == "enrich"))
    world = WorkCore.Wit.world(enrich, WorkCore.Graph.shared_types(g))

    assert world =~ "use types.{lead};"
    assert world =~ "func(a0: lead)"
    refute world =~ "func(a0: string)"
    assert WorkCore.Wit.validate(world) == :ok
  end

  test "check resolves host-cap edges against the catalog, not as dangling units" do
    write("svc.work", """
    # Service

    ```elixir
    server :svc, grant: [net: "api.example.com"] do
      def go, do: :ok
    end
    ```
    """)

    g = Graph.build_dir(@tmp)
    result = Graph.check(g)
    # a granted, known capability is NOT a dangling edge
    refute Enum.any?(result.dangling_edges, &(&1.to == "net"))
  end
end
