defmodule Workbooks.OQLRenderTest do
  @moduledoc """
  Pins the OQL kernel's Work→`work-*` HTML render — the product's core output
  (viewing a workbook via /w/:id, and the publish render path both go through
  Workbooks.OQL.render/1). Deterministic: the kernel render takes no LLM.
  """
  use ExUnit.Case, async: false

  setup_all do
    # The OQL kernel is a named GenServer; tolerate it already being up.
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  test "renders work-* elements to HTML, title + prose preserved" do
    html = Workbooks.OQL.render(~s(work-doc "Hello Workbook"\n  intro text here))
    assert is_binary(html) and byte_size(html) > 0
    assert html =~ "Hello Workbook"
    assert html =~ "<work-doc"
    assert html =~ "intro text here"
  end

  test "empty source → valid string, no crash" do
    assert is_binary(Workbooks.OQL.render(""))
  end

  test "parse_headlines extracts the node outline (level + title)" do
    src = ~s(work-doc "Demo"\n  work-section "Section A"\n  work-section "Section B")
    hs = Workbooks.OQL.parse_headlines(src)
    titles = Enum.map(hs, &(Map.get(&1, "title") || Map.get(&1, :title)))
    assert length(hs) == 3
    assert "Demo" in titles and "Section A" in titles and "Section B" in titles
  end

  test "validate of a well-formed workbook returns no errors (empty list)" do
    assert Workbooks.OQL.validate(~s(work-doc "Title"\n  some text)) == []
  end
end
