defmodule Workbooks.ModelsTest do
  @moduledoc """
  Unit tests for the OpenRouter model-discovery RENDERER (wb-d2nx.5). The pure
  `render/2` path is tested with a fixture catalog so there's no network flake —
  the live `fetch/1` (with its UA header + retry) is exercised by the toolkit
  eval suite (evals/exec-models.md), not here.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Models

  # A trimmed, realistic OpenRouter /models catalog slice.
  defp catalog do
    [
      %{
        "id" => "anthropic/claude-haiku-4.5",
        "name" => "Claude Haiku 4.5",
        "context_length" => 200_000,
        "architecture" => %{"modality" => "text+image->text"},
        "pricing" => %{"prompt" => "0.000001"}
      },
      %{
        "id" => "google/gemini-3-pro",
        "name" => "Gemini 3 Pro",
        "context_length" => 1_000_000,
        "architecture" => %{"modality" => "text+image+file->text"},
        "pricing" => %{"prompt" => "0.0000025"}
      },
      %{
        "id" => "openai/gpt-4o-mini",
        "name" => "GPT-4o mini",
        "top_provider" => %{"context_length" => 128_000},
        "architecture" => %{"modality" => "text->text"},
        "pricing" => %{"prompt" => "0.00000015"}
      }
    ]
  end

  test "empty query lists all, sorted by id, with a header" do
    out = Models.render(catalog(), "")
    [header | rows] = String.split(out, "\n")
    assert header == "MODEL\tCONTEXT\tMODALITY\t$/Mtok-in"
    assert length(rows) == 3
    # sorted by id: anthropic < google < openai
    ids = Enum.map(rows, &(String.split(&1, "\t") |> hd()))
    assert ids == ["anthropic/claude-haiku-4.5", "google/gemini-3-pro", "openai/gpt-4o-mini"]
  end

  test "query filters by id / name / modality (case-insensitive)" do
    assert Models.render(catalog(), "gemini") =~ "google/gemini-3-pro"
    refute Models.render(catalog(), "gemini") =~ "gpt-4o"
    # modality match: only the multimodal entries carry 'image'
    img = Models.render(catalog(), "image")
    assert img =~ "claude-haiku-4.5"
    assert img =~ "gemini-3-pro"
    refute img =~ "gpt-4o-mini"
  end

  test "no match returns a clear message, not an empty table" do
    assert Models.render(catalog(), "nonexistent-zzz") == ~s(no models match "nonexistent-zzz")
  end

  test "price is rendered as $ per 1M tokens; context falls back to top_provider" do
    row = Models.render(catalog(), "gpt-4o-mini") |> String.split("\n") |> List.last()
    [id, ctx, _modality, price] = String.split(row, "\t")
    assert id == "openai/gpt-4o-mini"
    assert ctx == "128000"
    # 0.00000015 * 1_000_000 = 0.15
    assert price == "$0.15"
  end

  test "missing pricing degrades to '?' rather than crashing" do
    bare = [%{"id" => "x/y", "name" => "Y", "context_length" => 1000, "architecture" => %{}}]
    row = Models.render(bare, "") |> String.split("\n") |> List.last()
    assert row == "x/y\t1000\ttext\t?"
  end
end
