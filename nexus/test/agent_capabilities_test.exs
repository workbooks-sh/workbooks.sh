defmodule Nexus.AgentCapabilitiesTest do
  use ExUnit.Case, async: true

  test "capabilities/1 resolves :all | :none | list from the parsed field" do
    assert Nexus.Agent.capabilities(%{capabilities: ["all"]}) == :all
    assert Nexus.Agent.capabilities(%{capabilities: ["none"]}) == :none
    assert Nexus.Agent.capabilities(%{capabilities: ["research", "video"]}) == ["research", "video"]
    # Absent/empty → sealed by default (none).
    assert Nexus.Agent.capabilities(%{}) == :none
  end

  test "admits?/2 — :all admits anything, :none admits nothing, list is membership" do
    waldo = %{capabilities: ["all"]}
    autopoet = %{capabilities: ["none"]}
    limited = %{capabilities: ["research"]}

    assert Nexus.Agent.admits?(waldo, "video")
    assert Nexus.Agent.admits?(waldo, :research)
    refute Nexus.Agent.admits?(autopoet, "video")
    assert Nexus.Agent.admits?(limited, "research")
    refute Nexus.Agent.admits?(limited, "video")
  end

  test "admitted/2 = selected ∩ admitted (ids normalized to strings)" do
    assert Nexus.Agent.admitted(%{capabilities: ["all"]}, [:research, :video]) == ["research", "video"]
    assert Nexus.Agent.admitted(%{capabilities: ["none"]}, ["research"]) == []
    assert Nexus.Agent.admitted(%{capabilities: ["research"]}, ["research", "video"]) == ["research"]
  end

  test "capabilities parse off a real agent block (capabilities :all)" do
    src = ~s|agent :w do\n  prompt "x"\n  capabilities :all\nend\n|
    [node] = Nexus.Literate.parse(src) |> then(&if(is_tuple(&1), do: elem(&1, 0), else: &1)) |> Enum.filter(&(is_map(&1) and &1[:kind] == "agent"))
    d = Nexus.Agent.def_from_unit(node)
    assert Nexus.Agent.capabilities(d) == :all
  end

  test "general?/1 — the workspace-scope tier" do
    assert Nexus.Agent.general?(%{scope: ["general"]})
    refute Nexus.Agent.general?(%{scope: ["workspace"]})
    refute Nexus.Agent.general?(%{})
    refute Nexus.Agent.general?(%{capabilities: ["all"]})
  end

  test "scope general parses off a real agent block; a plain agent is not general" do
    src = ~s|agent :w do\n  prompt "x"\n  capabilities :all\n  scope general\nend\n|
    [node] = Nexus.Literate.parse(src) |> then(&if(is_tuple(&1), do: elem(&1, 0), else: &1)) |> Enum.filter(&(is_map(&1) and &1[:kind] == "agent"))
    assert Nexus.Agent.general?(Nexus.Agent.def_from_unit(node))

    plain = ~s|agent :p do\n  prompt "x"\nend\n|
    [pn] = Nexus.Literate.parse(plain) |> then(&if(is_tuple(&1), do: elem(&1, 0), else: &1)) |> Enum.filter(&(is_map(&1) and &1[:kind] == "agent"))
    refute Nexus.Agent.general?(Nexus.Agent.def_from_unit(pn))
  end
end
