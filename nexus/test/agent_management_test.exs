defmodule Nexus.AgentManagementTest do
  use ExUnit.Case, async: true
  alias Nexus.Agent

  defp agent_node(src),
    do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code and &1.kind == "agent"))

  test "management parses the declared posture" do
    frozen = agent_node("agent :x do\n  prompt \"hi\"\n  management frozen\nend")
    assert Agent.management(frozen) == "frozen"
    refute Agent.autopoet_managed?(frozen)

    proposed = agent_node("agent :y do\n  prompt \"hi\"\n  management proposed\nend")
    assert Agent.management(proposed) == "proposed"
    refute Agent.autopoet_managed?(proposed)
  end

  test "absent posture defaults to managed (safe-to-improve)" do
    plain = agent_node("agent :z do\n  prompt \"hi\"\nend")
    assert Agent.management(plain) == "managed"
    assert Agent.autopoet_managed?(plain)
  end

  test "an unknown posture falls back to managed, never an arbitrary value" do
    bogus = agent_node("agent :q do\n  prompt \"hi\"\n  management wizard\nend")
    assert Agent.management(bogus) == "managed"
  end

  test "the structural triad is grant, ceiling, management" do
    assert Agent.structural_triad() == [:grant, :ceiling, :management]
  end
end
