defmodule Nexus.AgentHotreloadTest do
  use ExUnit.Case, async: false
  alias Nexus.{Agent, Autopoet.Lease}

  # current_perms/1 is private; we exercise it via the documented effect: a lease granted to a principal
  # is unioned into the effective grant, and a hot-swapped registered node changes the resolved perms.
  # We test the building blocks that current_perms composes (re-read node + effective_grant + leases),
  # since driving the full LLM loop is out of scope for a unit test.

  setup do
    Lease.clear()
    on_exit(fn -> Lease.clear() end)
    :ok
  end

  defp agent_node(name, body),
    do: "agent :#{name} do\n#{body}\nend" |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code and &1.kind == "agent"))

  test "registering a new definition changes what a re-read resolves (hot-swap)" do
    Agent.register(agent_node("hr", "  prompt \"v1\"\n  grant net"))
    assert Agent.def_from_unit(Agent.get("hr"))[:grant] == ["net"]

    # autopoet hot-swaps the definition mid-flight (adds llm, within a hypothetical ceiling)
    Agent.register(agent_node("hr", "  prompt \"v2\"\n  grant net, llm"))
    assert Agent.def_from_unit(Agent.get("hr"))[:grant] == ["net", "llm"]
  end

  test "a lease granted mid-run is picked up on the next effective-grant resolution" do
    base = Agent.effective_grant(["net"], ["net", "llm"], nil)
    assert base == ["net"]
    Lease.grant("hr2", "llm")
    # the per-turn resolution unions Lease.active(principal) — verify the lease is live for the principal
    assert "llm" in Lease.active("hr2")
  end
end
