defmodule Workbooks.OQLRenderTest do
  @moduledoc """
  Pins the OQL kernel's Org→HTML render — the product's core output (viewing a
  workbook via /w/:id, and the publish render path both go through
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

  test "renders Org headings + a list to HTML" do
    html = Workbooks.OQL.render("* Hello Workbook\nintro text here\n- one\n- two")
    assert is_binary(html) and byte_size(html) > 0
    assert html =~ "Hello Workbook"
    assert html =~ "<h1" or html =~ "<h2"
    assert html =~ "<li" and html =~ "one"
  end

  test "empty org → valid string, no crash" do
    assert is_binary(Workbooks.OQL.render(""))
  end

  test "parse_headlines extracts the org outline (level + title)" do
    hs = Workbooks.OQL.parse_headlines("* Demo\n** Section A\n** Section B")
    titles = Enum.map(hs, &(Map.get(&1, "title") || Map.get(&1, :title)))
    assert length(hs) == 3
    assert "Demo" in titles and "Section A" in titles and "Section B" in titles
  end

  test "validate of a well-formed org returns no errors (empty list)" do
    assert Workbooks.OQL.validate("* Title\nsome text") == []
  end
end
