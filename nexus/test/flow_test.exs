defmodule Nexus.FlowTest do
  @moduledoc "The `flow` kind — an ordered, runnable sequence of steps over the open effect engine."
  use ExUnit.Case, async: false

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  setup do
    Nexus.Effects.install_builtins()
    # a deterministic test effect (no LLM) that transforms the threaded value
    Nexus.Effects.register("shout", fn args, _e, _c -> String.upcase(args[:task] || "") end)
    :ok
  end

  test "a `flow` parses as a code unit of kind=flow" do
    n = unit("flow :pipe do\n  step :a, notify: \"hi\"\nend\n")
    assert n.kind == "flow"
    assert n.name == "pipe"
  end

  test "compile builds ordered steps; run threads the result through them in sequence" do
    n =
      unit("""
      flow :pipe do
        step :a, shout: "_"
        step :b, notify: "done"
      end
      """)

    spec = Nexus.Flow.compile(n)
    assert spec.name == "pipe"
    assert Enum.map(spec.steps, & &1.name) == ["a", "b"]

    assert {:ok, %{result: result, trace: trace}} = Nexus.Flow.run("pipe", "hello")
    assert result == "HELLO"        # step :a transformed the threaded input; :b (notify) kept it
    assert length(trace) == 2
  end

  test "a flow is runnable as an effect, so a hook can trigger it (run flow: ...)" do
    Nexus.Flow.compile(unit("flow :pipe do\n  step :a, shout: \"_\"\nend\n"))
    out = Nexus.Effects.run(%{name: "run", args: %{flow: "pipe", input: "hey"}}, %{}, %{})
    assert {:ok, %{result: "HEY"}} = out
  end
end
