defmodule Nexus.Browse.Search.RankTest do
  use ExUnit.Case, async: true

  alias Nexus.Browse.Search.Rank

  describe "canonical_url/1" do
    test "unwraps the DuckDuckGo uddg redirector" do
      wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&rut=abc"
      assert Rank.canonical_url(wrapped) == "https://example.com/page"
    end

    test "strips tracking params and www, drops fragment, normalizes trailing slash" do
      assert Rank.canonical_url("https://www.Example.com/foo/?utm_source=x&a=1#frag") ==
               "https://example.com/foo?a=1"
    end

    test "rejects non-http and hostless urls" do
      assert Rank.canonical_url("javascript:void(0)") == nil
      assert Rank.canonical_url("mailto:a@b.com") == nil
      assert Rank.canonical_url(nil) == nil
    end

    test "treats http and https + bare host as same canonical key" do
      assert Rank.canonical_url("http://example.com") == "https://example.com/"
      assert Rank.canonical_url("https://example.com/") == "https://example.com/"
    end
  end

  describe "dedupe/1" do
    test "collapses results pointing at the same canonical url" do
      results = [
        %{title: "A", url: "https://example.com/x?utm_source=q", snippet: "", rank: 1},
        %{title: "B", url: "https://www.example.com/x/", snippet: "", rank: 2},
        %{title: "C", url: "https://other.com/y", snippet: "", rank: 3}
      ]

      deduped = Rank.dedupe(results)
      assert length(deduped) == 2
      assert Enum.map(deduped, & &1.url) == ["https://example.com/x", "https://other.com/y"]
    end
  end

  describe "merge/2 (reciprocal-rank fusion)" do
    test "a result on two engines outranks a solo #1" do
      ddg = [
        %{title: "Shared", url: "https://shared.com/", snippet: "s", rank: 2},
        %{title: "DdgTop", url: "https://ddg-only.com/", snippet: "", rank: 1}
      ]

      mojeek = [
        %{title: "Shared longer title", url: "https://shared.com", snippet: "ss", rank: 2}
      ]

      merged = Rank.merge([{:ddg, ddg}, {:mojeek, mojeek}])
      top = hd(merged)

      assert top.url == "https://shared.com/"
      # surfaced by both engines
      assert top.engines == [:ddg, :mojeek]
      # keeps the longer title + snippet
      assert top.title == "Shared longer title"
      # solo #1 ranks below the agreed result
      assert Enum.at(merged, 1).url == "https://ddg-only.com/"
      assert top.score > Enum.at(merged, 1).score
    end

    test "respects per-engine weights" do
      a = [%{title: "A", url: "https://a.com/", snippet: "", rank: 1}]
      b = [%{title: "B", url: "https://b.com/", snippet: "", rank: 1}]

      merged = Rank.merge([{:weak, a}, {:strong, b}], %{weak: 0.5, strong: 2.0})
      assert hd(merged).url == "https://b.com/"
    end

    test "empty engine lists yield empty merge" do
      assert Rank.merge([{:ddg, []}, {:mojeek, []}]) == []
    end
  end
end
