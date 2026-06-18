defmodule Workbooks.GraphTest do
  use ExUnit.Case, async: true
  alias Workbooks.Graph

  setup do
    dir = Path.join(System.tmp_dir!(), "wbgraph_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "enrich.work"), """
    # Enrich

    server :enrich, grant: [net: "x"] do
      def enrich(lead), do: lead
    end
    """)

    File.write!(Path.join(dir, "flow.work"), """
    # Pipeline

    A flow that runs [[Enrich]] over the leads.

    flow :pipeline do
      def run(leads), do: Enum.map(leads, &Enrich.enrich/1)
    end
    """)

    File.write!(Path.join(dir, "score.work"), """
    # Scoring a lead

    server :score do
      def score(_lead), do: 1
    end
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "builds nodes + import edges, answers why/near, and resolves backlinks", %{dir: dir} do
    g = Graph.build_dir(dir)

    assert Map.has_key?(g.nodes, "enrich")
    assert Map.has_key?(g.nodes, "pipeline")
    assert Map.has_key?(g.nodes, "score")

    # the call Enrich.enrich/1 in :pipeline becomes a typed import edge
    assert %{from: "pipeline", to: "enrich", type: :import} in g.edges

    # work why :enrich → who depends on it
    assert "pipeline" in Graph.why(g, "enrich")
    # work near :enrich → its neighbourhood includes the pipeline edge
    assert Enum.any?(Graph.near(g, "enrich"), &(&1.from == "pipeline"))

    # the [[Enrich]] backlink resolves (matches the title/node), so the check is clean
    report = Graph.check(g)
    assert report.nodes == 3
    assert report.dangling_backlinks == []
    assert report.ok
  end

  test "a backlink to nothing is reported as dangling", %{dir: dir} do
    File.write!(Path.join(dir, "bad.work"), "# Bad\n\nSee [[Nonexistent Thing]] here.\n")
    report = Graph.build_dir(dir) |> Graph.check()

    assert Enum.any?(report.dangling_backlinks, fn {_, l} -> l == "[[Nonexistent Thing]]" end)
    refute report.ok
  end
end
