defmodule Nexus.OverlayTest do
  use ExUnit.Case, async: true
  alias Nexus.{Graph, Overlay}

  @tmp Path.join(System.tmp_dir!(), "wc_overlay_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    File.write!(Path.join(@tmp, "order.work"), "# Order\n\n```elixir\nresource :order do\n  defstruct id: \"\", total: 0\nend\n```\n")
    File.write!(Path.join(@tmp, "agent.work"), "# Agent\n\n```elixir\nserver :agent, grant: [net: \"x\"] do\n  def go, do: :ok\nend\n```\n")
    on_exit(fn -> File.rm_rf!(@tmp) end)
    {:ok, g: Graph.build_dir(@tmp)}
  end

  test "overlay is keyed by canonical Uid; put/get round-trips", _ do
    ov =
      Overlay.new()
      |> Overlay.put_data("Order", %{table: "orders", columns: ["id", "total"]})
      |> Overlay.put_observed(:agent, %{calls: 12, caps_used: ["net"]})

    # any identity surface form resolves to the same key
    assert Overlay.data(ov, "order").table == "orders"
    assert Overlay.observed(ov, "agent").calls == 12
  end

  test "with_overlay joins data + observed onto nodes; pure build stays clean", %{g: g} do
    # the pure graph carries no observed facet and only the declared data module
    assert g.nodes["order"].facets.observed == nil
    assert g.nodes["order"].facets.data == %{module: Order}

    ov =
      Overlay.new()
      |> Overlay.put_data("order", %{table: "orders", drift: []})
      |> Overlay.put_observed("agent", %{calls: 12, caps_used: ["net", "fs"]})

    lensed = Graph.with_overlay(g, ov)

    # data reality merged in (declared module preserved + ingested schema added)
    assert lensed.nodes["order"].facets.data.module == Order
    assert lensed.nodes["order"].facets.data.table == "orders"

    # execution reality attached
    assert lensed.nodes["agent"].facets.observed.calls == 12

    # capability drift falls out: granted net, but observed fs too
    declared_caps = Graph.host_caps(g, "agent")
    observed_caps = lensed.nodes["agent"].facets.observed.caps_used
    assert "fs" in (observed_caps -- declared_caps)

    # the original graph is untouched (overlay is a lens, not a mutation)
    assert g.nodes["agent"].facets.observed == nil
  end
end
