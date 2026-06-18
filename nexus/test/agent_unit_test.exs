defmodule Nexus.AgentUnitTest do
  @moduledoc "Agents authored as literate `.work` units (functions). Deterministic — no LLM."
  use ExUnit.Case, async: true

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  test "an `agent` unit parses as a code unit with kind=agent and the body as its prompt" do
    n = unit("agent :researcher do\n  You are a researcher. Find facts.\nend\n")
    assert n.kind == "agent"
    assert n.name == "researcher"
    assert n.body =~ "You are a researcher"
  end

  test "def_from_unit builds %{name, system} from the unit body" do
    n = unit("agent :helper do\n  Be terse.\nend\n")
    assert %{name: "helper", system: "Be terse."} = Nexus.Agent.def_from_unit(n)
  end

  test "Compile.unit routes an agent unit to the :agent lane (a runnable def, not wasm)" do
    n = unit("agent :helper do\n  Be terse.\nend\n")
    assert {:agent, %{name: "helper", system: "Be terse."}} = Nexus.Compile.unit(n)
  end
end
