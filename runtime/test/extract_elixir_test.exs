defmodule Workbooks.Extract.ElixirTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Literate, Extract}

  defp facts(src) do
    [code] = Literate.parse(src) |> Enum.filter(&(&1.type == :code))
    Extract.Elixir.extract(code)
  end

  test "extracts public defs as exports, with arity, and ignores privates" do
    src = """
    server :score do
      def score(%Lead{revenue: r}), do: r / 1_000
      def score(%Lead{} = lead, weight), do: lead.revenue * weight
      defp weigh(v, c), do: v / c
    end
    """

    %{exports: ex} = facts(src)
    assert {:score, 1} in ex
    assert {:score, 2} in ex
    refute Enum.any?(ex, fn {name, _} -> name == :weigh end)
  end

  test "extracts a defstruct as a record type with its field names" do
    src = """
    server :lead do
      defmodule Lead do
        defstruct name: "", revenue: 0, status: :new
      end
    end
    """

    %{types: ty} = facts(src)
    assert {:record, [name: "", revenue: 0, status: :new]} in ty
    assert {:module, :Lead} in ty
  end

  test "extracts remote calls to other units" do
    src = """
    flow :pipeline do
      def run(leads) do
        leads
        |> Enum.map(&Enrich.enrich/1)
        |> Enum.map(fn l -> Score.score(l) end)
      end
    end
    """

    %{calls: ca} = facts(src)
    assert {Score, :score, 1} in ca
  end

  test "a guarded def keeps its name and arity" do
    src = """
    server :tax do
      def quote(amount, region) when is_integer(amount), do: amount
    end
    """

    %{exports: ex} = facts(src)
    assert {:quote, 2} in ex
  end

  test "a foreign-language node (no ast) yields empty facts, gracefully" do
    [code] = Literate.parse("rust :forecast do\n  fn go() {}\nend\n") |> Enum.filter(&(&1.type == :code))
    assert %{exports: [], types: [], calls: []} = Extract.Elixir.extract(code)
  end
end
