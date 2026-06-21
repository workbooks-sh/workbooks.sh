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

  test "a structured agent block defines prompt + tools + grant + limit (the sandboxed function)" do
    n =
      unit("""
      agent :coder do
        prompt \"\"\"
        You fix failing tests in /work.
        \"\"\"
        tools coreutils, git, rg
        grant fs, exec
        limit turns: 40, timeout: 180_000
      end
      """)

    d = Nexus.Agent.def_from_unit(n)
    assert d.name == "coder"
    assert d.system =~ "You fix failing tests"
    assert d.tools == ["coreutils", "git", "rg"]
    assert d.grant == ["fs", "exec"]
    assert d.limit == [turns: 40, timeout: 180_000]
  end

  test "the agent spec is open: any field is captured; grant is validated; limit is enforced-dims-only" do
    n =
      unit("""
      agent :coder do
        prompt \"\"\"
        Fix it.
        \"\"\"
        grant fs, exec, boguscap
        limit turns: 5, timeout: 1000, tokens: 99
        model "anthropic/claude"
        context window: 8000
        safety stop: "STOP"
        hooks on: "DONE", emit: "task.done"
      end
      """)

    d = Nexus.Agent.def_from_unit(n)
    assert d.grant == ["fs", "exec"]                       # boguscap dropped (not grantable)
    assert d.limit == [turns: 5, timeout: 1000]            # tokens dropped (not an enforced dim)
    assert d.model == "anthropic/claude"                   # forward-declared field, captured verbatim
    assert d.context == [window: 8000]
    assert d.safety == [stop: "STOP"]
    assert d.hooks == [on: "DONE", emit: "task.done"]
  end

  test "agents register for run-by-name; unknown name errors cleanly" do
    n = unit("agent :coder do\n  prompt \"\"\"\n  Fix it.\n  \"\"\"\n  tools coreutils\nend\n")
    Nexus.Agent.register(n)
    assert Nexus.Agent.get("coder") == n
    assert Nexus.Agent.get("coder") |> Nexus.Agent.def_from_unit() |> Map.get(:tools) == ["coreutils"]
    assert {:error, {:no_agent, "ghost"}} = Nexus.Agent.run_named("ghost", "x")
  end

  test "Kits.summary/1 scopes the catalog to an agent's declared tools" do
    Nexus.Agent.Kits.register("rg", "rg.wasm", summary: "search")
    Nexus.Agent.Kits.register("git", "git.wasm", summary: "version control")
    scoped = Nexus.Agent.Kits.summary(["rg"])
    assert scoped =~ "rg"
    refute scoped =~ "version control"
  end
end
