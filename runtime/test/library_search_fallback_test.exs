defmodule Workbooks.LibrarySearchFallbackTest do
  @moduledoc """
  Pins the embeddings-down keyword fallback for the agent's recall (search_dir).
  When Workbooks.Embed is unavailable, search must degrade to substring/term
  ranking over the chunks it read — NOT silently return nothing. Deterministic
  (literal_rank seam; no embed model).
  """
  use ExUnit.Case, async: true
  alias Workbooks.Library

  defp chunk(text), do: %{path: "p.org", headline: "h", text: text}

  test "ranks chunks by query-term overlap, most hits first" do
    chunks = [chunk("nothing relevant here"), chunk("we handle auth headers in the broker"), chunk("auth only")]
    [top | _] = Library.literal_rank_for_test(chunks, "auth headers", 5)
    assert top.text =~ "auth headers"
    assert top.score >= 2
  end

  test "drops zero-hit chunks (honest: no fabricated matches)" do
    chunks = [chunk("alpha beta"), chunk("gamma delta")]
    assert Library.literal_rank_for_test(chunks, "zzz nomatch", 5) == []
  end

  test "respects k" do
    chunks = for i <- 1..10, do: chunk("auth token #{i}")
    assert length(Library.literal_rank_for_test(chunks, "auth token", 3)) == 3
  end

  test "search_dir on an empty dir returns [] (no embed call, deterministic)" do
    dir = Path.join(System.tmp_dir!(), "lsf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    assert Library.search_dir(dir, "anything") == []
  end
end
