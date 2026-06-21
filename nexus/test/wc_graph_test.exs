defmodule Nexus.GraphTest do
  use ExUnit.Case, async: true
  alias Nexus.Graph

  @tmp Path.join(System.tmp_dir!(), "wc_graph_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  defp write(name, body), do: File.write!(Path.join(@tmp, name), body)

  describe "query API + dogfood render" do
    setup do
      write("chart.work", "# Chart\nsvelte\nclient svelte :chart do\n  export function Chart() {}\nend\n")

      write("panel.work", """
      # Panel

      client solid :panel do
        import { chart } from "work://chart"
        export function Panel() {}
      end
      """)

      write("svc.work", """
      # Service

      server :svc, grant: [net: "api.example.com"] do
        def go, do: :ok
      end
      """)

      {:ok, g: Nexus.Graph.build_dir(@tmp)}
    end

    test "get / units / dependencies / dependents / host_caps", %{g: g} do
      assert Nexus.Graph.get(g, "panel").id == "panel"
      assert "chart" in Nexus.Graph.dependencies(g, "panel")
      assert "panel" in Nexus.Graph.dependents(g, "chart")
      assert "net" in Nexus.Graph.host_caps(g, "svc")
      assert Enum.any?(Nexus.Graph.units(g, lang: "elixir"), &(&1.id == "svc"))
    end

    test "neighbors filters by scope/dir", %{g: g} do
      caps = Nexus.Graph.neighbors(g, "svc", scope: :host_cap)
      assert Enum.all?(caps, &(&1.scope == :host_cap))
      ins = Nexus.Graph.neighbors(g, "chart", dir: :in)
      assert Enum.any?(ins, &(&1.from == "panel"))
    end

    test "trace gives the cross-layer view; path walks dependencies", %{g: g} do
      t = Nexus.Graph.trace(g, "panel")
      assert t.identity.package == "work:panel"
      assert "chart" in t.dependencies
      assert Map.has_key?(t.facets, :source)
      assert Nexus.Graph.path(g, "panel", "chart") == ["panel", "chart"]
    end

    test "dogfood: graph renders as a work-* workbook (no JSON)", %{g: g} do
      html = Nexus.Graph.Render.to_html(g, title: "Test graph")
      assert html =~ "<document-view>"
      assert html =~ "<work-flow>"
      assert html =~ ~s(from="panel")
      assert html =~ ~s(to="chart")
      assert html =~ "work:svc"
      # composition-as-source: it's HTML, not a JSON blob
      refute html =~ ~r/\{\s*"/
    end
  end

  test "node carries identity + per-layer facets" do
    write("orders.work", """
    # Orders

    resource :order do
      defstruct id: "", total: 0
    end
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

    server :svc, grant: [net: "api.example.com"] do
      def go, do: :ok
    end
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

    defmodule Lead do
      defstruct name: "", score: 0
    end
    """)

    write("enrich.work", """
    # Enrich

    server :enrich do
      def run(%Lead{} = lead), do: lead
    end
    """)

    g = Nexus.Graph.build_dir(@tmp)

    # the unified type registry sees the cross-file record
    assert Map.has_key?(g.types, "lead")
    {iface, names} = Nexus.Graph.shared_types(g)
    assert "lead" in names
    assert iface =~ "record lead"

    # the per-unit world resolved against the registry types the param as the
    # record (NOT string) and is self-contained valid WIT
    enrich = Path.join(@tmp, "enrich.work") |> File.read!() |> Nexus.Literate.parse() |> Enum.find(&(&1[:name] == "enrich"))
    world = Nexus.Wit.world(enrich, Nexus.Graph.shared_types(g))

    assert world =~ "use types.{lead};"
    assert world =~ "func(a0: lead)"
    refute world =~ "func(a0: string)"
    assert Nexus.Wit.validate(world) == :ok
  end

  test "check resolves host-cap edges against the catalog, not as dangling units" do
    write("svc.work", """
    # Service

    server :svc, grant: [net: "api.example.com"] do
      def go, do: :ok
    end
    """)

    g = Graph.build_dir(@tmp)
    result = Graph.check(g)
    # a granted, known capability is NOT a dangling edge
    refute Enum.any?(result.dangling_edges, &(&1.to == "net"))
  end
end
