defmodule Nexus.FlowProgressTest do
  @moduledoc """
  Live progress for flows: Nexus.Flow.run emits flow_start → step_start/step_end (per step) → flow_end on
  the ctx :emit channel, so a UI can watch a flow advance through its steps in real time.
  """
  use ExUnit.Case, async: false

  test "run emits flow + per-step lifecycle events in order" do
    spec = %{
      name: "demo",
      steps: [
        %{name: :one, effect: %{name: "notify", args: %{}}},
        %{name: :two, effect: %{name: "notify", args: %{}}}
      ]
    }

    Nexus.Flow.register(spec)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(agent, &[{ev.type, ev[:step]} | &1]) end

    {:ok, _} = Nexus.Flow.run("demo", "input", %{emit: emit})

    events = Agent.get(agent, & &1) |> Enum.reverse()

    assert [
             {"flow_start", nil},
             {"step_start", "one"},
             {"step_end", "one"},
             {"step_start", "two"},
             {"step_end", "two"},
             {"flow_end", nil}
           ] = events
  end

  test "no :emit in ctx → no crash (events are a no-op)" do
    Nexus.Flow.register(%{name: "quiet", steps: [%{name: :x, effect: %{name: "notify", args: %{}}}]})
    assert {:ok, _} = Nexus.Flow.run("quiet", "in", %{})
  end
end
