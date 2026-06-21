defmodule Nexus.InstrumentTest do
  @moduledoc "The #event auto-instrument seam: a tagged unit emits → a matching hook fires effects."
  use ExUnit.Case, async: false

  test "a #event-tagged unit emits, carrying its other #tags; a matching hook fires" do
    Nexus.Effects.install_builtins()
    parent = self()
    Nexus.Effects.register("probe", fn _a, ev, _c -> send(parent, {:fired, ev[:kind], ev[:tags]}); :ok end)

    Nexus.Hook.register(%{
      name: "on_deploy",
      match: %{tags: ["deploy"]},
      effects: [%{name: "probe", args: %{}}],
      visible_to: nil,
      title: "on_deploy"
    })

    node = %{kind: "server", name: "ship", refs: ["#event", "#deploy"]}
    assert %{kind: "server.ship"} = Nexus.Events.instrument(node, %{title: "shipped"})

    assert_receive {:fired, "server.ship", tags}, 1_000
    assert "deploy" in tags
    refute "event" in tags
  end

  test "no #event tag → no emission" do
    assert :noop = Nexus.Events.instrument(%{kind: "server", name: "x", refs: ["#deploy"]})
  end
end
