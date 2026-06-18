defmodule Nexus.Graph.VizTest do
  use ExUnit.Case, async: true
  alias Nexus.{Graph, Overlay, Graph.Viz}

  @tmp Path.join(System.tmp_dir!(), "nx_viz_test")

  setup do
    File.rm_rf!(@tmp); File.mkdir_p!(@tmp)
    File.write!(Path.join(@tmp, "o.work"), "# O\n\n```elixir\nresource :order do\n  id :text\nend\n```\n")
    on_exit(fn -> File.rm_rf!(@tmp) end)
    {:ok, g: Graph.build_dir(@tmp)}
  end

  test "renders an svg graph with a node and reality badges", %{g: g} do
    ov = Overlay.put_observed(Overlay.new(), "order", %{runs: 3, tokens: 10})
    html = Viz.to_html(Graph.with_overlay(g, ov), title: "T")

    assert html =~ "<svg"
    assert html =~ ~s(data-id="order")
    # the embedded inspector data carries the reality facet
    assert html =~ "observed"
    assert html =~ "darkreader-lock"
  end
end
