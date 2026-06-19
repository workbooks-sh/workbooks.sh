defmodule Nexus.Browse.Search.CorporaTest do
  use ExUnit.Case, async: true

  alias Nexus.Browse.Search.Corpora

  defp fixture(name), do: File.read!(Path.join([__DIR__, "..", "fixtures", "corpora", name]))

  describe "build_url/3" do
    test "encodes query into each open-corpus endpoint" do
      assert Corpora.build_url(:wikipedia, "BEAM vm", 5) =~
               "en.wikipedia.org/w/api.php?action=query&list=search"

      assert Corpora.build_url(:wikipedia, "BEAM vm", 5) =~ "srsearch=BEAM+vm"
      assert Corpora.build_url(:hackernews, "elixir", 3) =~ "hn.algolia.com/api/v1/search"
      assert Corpora.build_url(:openalex, "x", 3) =~ "api.openalex.org/works"
      assert Corpora.build_url(:archive, "x", 3) =~ "archive.org/advancedsearch.php"
    end

    test "commoncrawl treats query as a host wildcard" do
      assert Corpora.build_url(:commoncrawl, "elixir-lang.org", 3) =~ "elixir-lang.org%2F%2A"
      # bare-token query → falls back to <token>.com/*
      assert Corpora.build_url(:commoncrawl, "elixir", 3) =~ "elixir.com%2F%2A"
    end
  end

  describe "parse/2" do
    test "wikipedia → article urls + stripped snippets" do
      results = Corpora.parse(:wikipedia, fixture("wikipedia.json"))
      assert results != []
      r = hd(results)
      assert r.source == :wikipedia
      assert r.rank == 1
      assert r.url =~ "en.wikipedia.org/wiki/"
      refute r.snippet =~ "<span"
    end

    test "hackernews → external link graph with points" do
      results = Corpora.parse(:hackernews, fixture("hn.json"))
      assert results != []
      r = hd(results)
      assert r.source == :hackernews
      assert r.title != ""
      assert String.starts_with?(r.url, "http")
    end

    test "openalex → scholarly works" do
      results = Corpora.parse(:openalex, fixture("openalex.json"))
      assert results != []
      assert hd(results).source == :openalex
      assert hd(results).title != ""
    end

    test "archive → IA item details urls" do
      results = Corpora.parse(:archive, fixture("archive.json"))
      assert Enum.all?(results, &(&1.url =~ "archive.org/details/"))
    end

    test "blocked/garbage body → [] not raise" do
      assert Corpora.parse(:wikipedia, "<html>captcha</html>") == []
      assert Corpora.parse(:openalex, "") == []
    end
  end

  describe "parse_commoncrawl/1 (JSONL)" do
    test "parses newline-delimited index rows" do
      results = Corpora.parse_commoncrawl(fixture("commoncrawl.jsonl"))
      assert results != []
      r = hd(results)
      assert r.source == :commoncrawl
      assert String.starts_with?(r.url, "http")
    end

    test "garbage → []" do
      assert Corpora.parse_commoncrawl("not json\n{bad}") == []
    end
  end

  test "names/0 lists the five corpora" do
    assert Enum.sort(Corpora.names()) ==
             Enum.sort([:wikipedia, :hackernews, :openalex, :archive, :commoncrawl])
  end
end
