defmodule Nexus.LiterateTest do
  use ExUnit.Case, async: true
  alias Nexus.Literate

  defp kinds(nodes), do: Enum.map(nodes, & &1.type)
  defp by_type(nodes, t), do: Enum.filter(nodes, &(&1.type == t))

  test "splits prose, headings, code blocks, and flat declarations" do
    src = """
    # Compute

    A unit declares **where it runs** — there are two places.

    server :score do
      def score(%Lead{revenue: r}) do
        r / 1_000
      end
    end

    @statuses [:new, :enriched, :scored]
    """

    nodes = Literate.parse(src)
    assert :heading in kinds(nodes)
    assert :prose in kinds(nodes)
    assert :code in kinds(nodes)
    assert :decl in kinds(nodes)

    [heading] = by_type(nodes, :heading)
    assert heading.text == "Compute"
    assert heading.level == 1
  end

  test "a code block's header is parsed into kind / lang / name, and nested do…end don't close it early" do
    src = """
    server rust :enrich, in: :pricing do
      def f do
        case x do
          1 -> :ok
        end
      end
    end
    """

    [code] = Literate.parse(src) |> by_type(:code)
    assert code.kind == "server"
    assert code.lang == "rust"
    assert code.name == "enrich"
    # the nested `case … do … end` and `def … do … end` stay in the body
    assert code.body =~ "case x do"
    assert code.body =~ "1 -> :ok"
    refute code.body =~ "server rust"
  end

  test "a bare language block (rust :forecast do) gets lang from the kind word" do
    [code] = Literate.parse("rust :forecast do\n  fn go() {}\nend\n") |> by_type(:code)
    assert code.kind == "rust"
    assert code.lang == "rust"
    assert code.name == "forecast"
  end

  test "a multi-line flat declaration is held together by bracket balance" do
    src = """
    data :leads, of: Lead, from: values([
      %Lead{name: "Acme", score: 70},
      %Lead{name: "Globex", score: 41}
    ])

    The leads above render by default.
    """

    nodes = Literate.parse(src)
    [decl] = by_type(nodes, :decl)
    assert decl.text =~ "data :leads"
    assert decl.text =~ "Globex"
    assert decl.text =~ "])"
    # the following sentence is its own prose node, not swallowed into the decl
    assert [%{type: :prose, text: "The leads above render by default."}] = by_type(nodes, :prose)
  end

  test "inline references are extracted from prose, but not invented from plain words" do
    src = "See [[Score a lead]] and the :enrich unit, the @statuses enum, and #b2b — at work://sales/score."
    [prose] = Literate.parse(src) |> by_type(:prose)

    assert "[[Score a lead]]" in prose.refs
    assert ":enrich" in prose.refs
    assert "@statuses" in prose.refs
    assert "#b2b" in prose.refs
    assert "work://sales/score" in prose.refs
  end

  test "refs ignore backlinks inside inline code, and don't span newlines" do
    # `[[backlink]]` in backticks is a syntax example, not a real reference
    assert Literate.refs("write `[[backlink]]` to link") == []
    # a real backlink beside a coded example still resolves
    assert "[[Score]]" in Literate.refs("see [[Score]] and write `[[example]]`")
    refute "[[example]]" in Literate.refs("see [[Score]] and write `[[example]]`")
    # a backlink may not span a line break
    assert Literate.refs("[[The\nDock]]") == []
  end

  test "a prose paragraph full of backlinks is NOT mistaken for a declaration" do
    src = "Foundation ([[Types]], [[References]]) · pages ([[Page]], [[Design]])."
    assert [%{type: :prose}] = Literate.parse(src)
  end
end
