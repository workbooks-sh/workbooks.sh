defmodule Nexus.UnitTest do
  use ExUnit.Case, async: true
  alias Nexus.{Literate, Unit}

  defp unit(src), do: Literate.parse(src) |> Enum.find(&(&1.type == :code))

  test "compiles and runs a self-contained server unit's Elixir on the BEAM" do
    node = unit("server :calc do\n  def double(x), do: x * 2\n  def add(a, b), do: a + b\nend\n")

    assert {:ok, mod} = Unit.compile(node)
    assert function_exported?(mod, :double, 1)
    assert Unit.run(node, :double, [21]) == 42
    assert Unit.run(node, :add, [2, 3]) == 5
  end

  test "runs a unit that uses real Elixir idioms (pipes, with-railway, comprehensions)" do
    node =
      unit("""
      server :pipe do
        def topn(xs, n) do
          xs
          |> Enum.sort(:desc)
          |> Enum.take(n)
        end

        def safe(x) do
          with {:ok, v} <- check(x), do: v, else: (_ -> 0)
        end

        defp check(x) when x > 0, do: {:ok, x}
        defp check(_), do: :error
      end
      """)

    assert Unit.run(node, :topn, [[3, 1, 4, 1, 5], 2]) == [5, 4]
    assert Unit.run(node, :safe, [7]) == 7
    assert Unit.run(node, :safe, [-1]) == 0
  end

  test "errors cleanly on a non-unit and on a body that can't compile" do
    assert Unit.compile(%{name: "x", ast: nil}) == {:error, :not_a_unit}

    # a head pattern on an undefined struct can't compile → {:error, _}, not a crash
    bad = unit("server :bad do\n  def f(%Ghost{} = g), do: g\nend\n")
    assert {:error, _} = Unit.compile(bad)
  end
end
