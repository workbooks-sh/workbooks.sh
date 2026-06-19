defmodule Nexus.Browse.Search.SemanticTest do
  use ExUnit.Case, async: true

  alias Nexus.Browse.Search.Semantic

  test "reranks candidates by blended rrf + semantic score" do
    candidates = [
      %{title: "Italian pasta recipes", snippet: "carbonara and pesto", url: "u1", score: 0.9},
      %{title: "Erlang BEAM scheduler", snippet: "concurrency and processes", url: "u2", score: 0.5}
    ]

    # With alpha=1.0 (pure semantic), the on-topic candidate should win despite lower RRF.
    [top | _] = Semantic.rerank("BEAM concurrency erlang", candidates, alpha: 1.0)
    assert top.url == "u2"
    assert Map.has_key?(top, :semantic)
    assert Map.has_key?(top, :rrf)
  end

  test "empty candidate list → []" do
    assert Semantic.rerank("q", [], []) == []
  end

  test "alpha=0 preserves rrf order" do
    candidates = [
      %{title: "a", snippet: "", url: "u1", score: 0.2},
      %{title: "b", snippet: "", url: "u2", score: 0.8}
    ]

    [top | _] = Semantic.rerank("anything", candidates, alpha: 0.0)
    assert top.url == "u2"
  end
end
