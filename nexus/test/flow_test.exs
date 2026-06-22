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

  test "a `parallel do … end` group fans out on the threaded value and gathers results in order" do
    # a second deterministic effect so we can prove substep ORDER is preserved
    Nexus.Effects.register("rev", fn args, _e, _c -> String.reverse(args[:task] || "") end)

    n =
      unit("""
      flow :fan do
        step :prep, shout: "_"
        parallel do
          step :a, shout: "_"
          step :b, rev: "_"
        end
      end
      """)

    spec = Nexus.Flow.compile(n)
    assert Enum.map(spec.steps, & &1.name) == ["prep", "parallel"]

    # input "ab" → prep upcases to "AB"; the group runs both substeps on "AB" concurrently,
    # gathering [shout("AB"), rev("AB")] = ["AB", "BA"] in declaration order
    assert {:ok, %{result: result}} = Nexus.Flow.run("fan", "ab")
    assert result == ["AB", "BA"]
  end

  test "parallel substeps actually run concurrently, not sequentially" do
    Nexus.Effects.register("slow", fn args, _e, _c ->
      Process.sleep(200)
      String.upcase(args[:task] || "")
    end)

    Nexus.Flow.compile(
      unit("""
      flow :slowfan do
        parallel do
          step :a, slow: "_"
          step :b, slow: "_"
          step :c, slow: "_"
        end
      end
      """)
    )

    {micros, {:ok, %{result: result}}} = :timer.tc(fn -> Nexus.Flow.run("slowfan", "x") end)

    assert result == ["X", "X", "X"]
    # three 200ms steps run concurrently finish well under the 600ms a sequential run would take
    assert micros < 450_000
  end
end
