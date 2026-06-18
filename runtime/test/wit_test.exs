defmodule Workbooks.WitTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Literate, Wit}

  defp code(src), do: Literate.parse(src) |> Enum.find(&(&1.type == :code))

  test "exports come from public defs; an enriched signature with a grant adds an import" do
    src = """
    server :enrich, grant: [net: "api.crm.com"] do
      def enrich(lead), do: lead
      defp helper(x), do: x
    end
    """

    world = src |> code() |> Wit.world()

    assert world =~ "world enrich {"
    assert world =~ "export enrich: func(a0: string) -> string;"
    # private def is not an export
    refute world =~ "helper"
    # the net grant becomes a host import
    assert world =~ "import host-net;"
  end

  test "a struct-pattern argument types as its record in the func signature" do
    world = code("server :score do\n  def score(%Lead{} = lead), do: lead.revenue\nend\n") |> Wit.world()
    assert world =~ "export score: func(a0: lead) -> string;"
  end

  test "a unit with no public signature gets the default run export and no imports" do
    world = code("server :noop do\n  @x 1\nend\n") |> Wit.world()
    assert world =~ "export run: func(input: string) -> string;"
    refute world =~ "import "
  end

  test "underscores in names become hyphens (WIT identifiers)" do
    world = code("server :risk_box do\n  def risk_score(l), do: l\nend\n") |> Wit.world()
    assert world =~ "world risk-box {"
    assert world =~ "export risk-score: func(a0: string) -> string;"
  end

  test "grants/1 reads both keyword and bare grant forms" do
    assert Wit.grants(%{header: "server :x, grant: [net: \"a\", kv: :secrets]"}) == ["net", "kv"]
    assert Wit.grants(%{header: "sandbox :rates, grant: [:net, :kv]"}) == ["net", "kv"]
  end

  test "a foreign-language unit's exports come through too" do
    world = code("python :risk do\n  def risk_score(lead):\n    return 0\nend\n") |> Wit.world()
    assert world =~ "export risk-score: func() -> string;"
  end
end
