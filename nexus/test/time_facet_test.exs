defmodule Nexus.TimeFacetTest do
  @moduledoc "The `.work` time facet: a `hook` `trigger` arms the scheduler; a `flow` step `after:` gates."
  use ExUnit.Case, async: false

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  setup do
    Nexus.Effects.install_builtins()
    Nexus.Scheduler.clear()
    on_exit(fn -> Nexus.Scheduler.clear() end)
    :ok
  end

  test "a hook with `trigger every:` arms a repeating schedule carrying its effects" do
    n =
      unit("""
      hook :nightly do
        trigger cron: "0 2 * * *"
        notify "maintenance"
      end
      """)

    spec = Nexus.Hook.compile(n)
    assert spec.trigger == [cron: "0 2 * * *"]

    assert [entry] = Nexus.Scheduler.list()
    assert entry.name == "nightly"
    assert [%{name: "notify"}] = entry.effects
    assert Nexus.Time.repeating?(entry.spec)
  end

  test "a hook can carry BOTH a match and a trigger (event- and time-driven are independent)" do
    n =
      unit("""
      hook :both do
        match tags: [:deploy]
        trigger every: "1h"
        notify "ping"
      end
      """)

    spec = Nexus.Hook.compile(n)
    assert spec.match == %{tags: [:deploy]}
    assert spec.trigger == [every: "1h"]
    # still matches events for the bus...
    assert Nexus.Hook.matches?(spec.match, %{tags: [:deploy]})
    # ...and is armed on the scheduler.
    assert [%{name: "both"}] = Nexus.Scheduler.list()
  end

  test "a hook without a trigger arms nothing" do
    Nexus.Hook.compile(unit("hook :plain do\n  match tags: [:x]\n  notify \"y\"\nend\n"))
    assert [] = Nexus.Scheduler.list()
  end

  test "a flow step `after:` gates the step with a real delay" do
    n =
      unit("""
      flow :paced do
        step :a, after: "0s", notify: "go"
      end
      """)

    spec = Nexus.Flow.compile(n)
    assert [%{name: "a", after_ms: 0}] = spec.steps
    assert {:ok, %{trace: [_]}} = Nexus.Flow.run("paced", "in")
  end

  test "a bare `wait` step parses as a delay-only step" do
    n = unit("flow :w do\n  step :a, notify: \"x\"\n  wait \"0s\"\nend\n")
    spec = Nexus.Flow.compile(n)
    assert Enum.map(spec.steps, & &1.name) == ["a", "wait"]
  end
end
