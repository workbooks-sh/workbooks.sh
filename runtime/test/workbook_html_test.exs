defmodule Workbooks.WorkbookHtmlTest do
  @moduledoc """
  Pins the HTML-native workbook reader (`Workbooks.Workbook`, Floki). A workbook
  IS HTML built from `work-*` web components; the backend reads its STRUCTURE with
  a standard parser, never a bespoke kernel. Deterministic: pure Floki, no LLM.

    * parse_headlines — the `work-*` element outline (level + title + attrs)
    * tangle_plan     — the build plan (work-flow → world, work-component → leaf)
    * validate        — diagnostics over the parsed component graph
  """
  use ExUnit.Case, async: true

  alias Workbooks.Workbook

  test "parse_headlines extracts the work-* node outline (level + title)" do
    src = ~s(<work-doc title="Demo"><work-section title="Section A"></work-section><work-section title="Section B"></work-section></work-doc>)
    hs = Workbook.parse_headlines(src)
    titles = Enum.map(hs, & &1["title"])
    assert length(hs) == 3
    assert "Demo" in titles and "Section A" in titles and "Section B" in titles
    # Depth: the doc is level 1, its sections level 2.
    assert Enum.find(hs, &(&1["title"] == "Demo"))["level"] == 1
    assert Enum.find(hs, &(&1["title"] == "Section A"))["level"] == 2
  end

  test "non-work HTML wrappers are descended through, not treated as nodes" do
    src = ~s(<div class="wrap"><work-note title="Inner"></work-note></div>)
    hs = Workbook.parse_headlines(src)
    assert [%{"title" => "Inner", "level" => 1}] = hs
  end

  test "validate of a well-formed workbook returns no errors (empty list)" do
    assert Workbook.validate(~s(<work-doc title="Title"><p>some text</p></work-doc>)) == []
  end

  test "validate flags a dangling input + a langless component" do
    src = """
    <work-flow title="broken">
      <work-component title="needs" lang="js" in="missing"></work-component>
      <work-component title="nolang"></work-component>
    </work-flow>
    """

    diags = Workbook.validate(src)
    messages = Enum.map(diags, & &1["message"])
    assert Enum.any?(messages, &(&1 =~ "no upstream producer"))
    assert Enum.any?(messages, &(&1 =~ "no source block"))
  end

  test "tangle_plan builds a world with components + dataflow edges" do
    src = """
    <work-flow title="etl">
      <work-component title="extract" lang="rust" out="raw"></work-component>
      <work-component title="transform" lang="rust" in="raw" out="clean" uses="fetch"></work-component>
      <work-component title="load" lang="rust" in="clean"></work-component>
    </work-flow>
    """

    plan = Workbook.tangle_plan(src)
    [world] = plan["worlds"]
    assert world["name"] == "etl"
    assert length(world["components"]) == 3
    assert world["imports"] == ["fetch"]
    # extract→transform and transform→load along the out→in edges.
    edges = Enum.map(world["edges"], &{&1["from"], &1["to"]})
    assert {"extract", "transform"} in edges
    assert {"transform", "load"} in edges
  end

  test "tangle_plan carries each component's body as src + its build attrs" do
    src = ~s|<work-flow title="f"><work-component title="add" lang="rust" out="sum" dir="crates/add">pub fn add() {}</work-component></work-flow>|
    [world] = Workbook.tangle_plan(src)["worlds"]
    [comp] = world["components"]
    assert comp["name"] == "add"
    assert comp["lang"] == "rust"
    assert comp["dir"] == "crates/add"
    assert comp["src"] =~ "pub fn add"
  end

  test "tangle_plan carries each unit's target + grants; grants flow into world imports" do
    src = """
    <work-flow title="svc">
      <work-component title="enrich" lang="rust" target="sandbox" grant="net" out="scored">x</work-component>
      <work-component title="render" lang="js" target="client" uses="ui">y</work-component>
      <work-component title="schema" target="bogus">z</work-component>
    </work-flow>
    """

    [world] = Workbook.tangle_plan(src)["worlds"]
    [enrich, render, schema] = world["components"]
    assert enrich["target"] == "sandbox"
    assert enrich["grants"] == ["net"]
    assert render["target"] == "client"
    # an unrecognized target normalizes to nil = a static definition.
    assert schema["target"] == nil
    # grants ∪ uses make up the world's WIT imports (sorted, deduped).
    assert world["imports"] == ["net", "ui"]
  end

  test "bare work-components with no flow still form an implicit build world" do
    src = ~s(<work-component title="lone" lang="js" out="x">export default 1</work-component>)
    [world] = Workbook.tangle_plan(src)["worlds"]
    assert [%{"name" => "lone"}] = world["components"]
  end
end
