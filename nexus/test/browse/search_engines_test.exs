defmodule Nexus.Browse.Search.EnginesTest do
  use ExUnit.Case, async: true

  alias Nexus.Browse.Search.Engines
  alias Nexus.Browse.Search.Rank

  defp fixture(name), do: File.read!(Path.join([__DIR__, "..", "fixtures", "search", name]))

  describe "build_url/2" do
    test "encodes the query into each engine's endpoint" do
      assert Engines.build_url(:ddg, "gen server") ==
               "https://html.duckduckgo.com/html/?q=gen+server"

      assert Engines.build_url(:mojeek, "a&b") == "https://www.mojeek.com/search?q=a%26b"
    end
  end

  describe "parse/2 — DuckDuckGo-HTML (uddg-wrapped)" do
    test "extracts titles + redirector urls + snippets in order" do
      results = Engines.parse(:ddg, fixture("ddg.html"))

      assert length(results) == 2
      [r1, r2] = results

      assert r1.title == "GenServer — Elixir v1.19.5"
      assert r1.rank == 1
      assert String.contains?(r1.url, "uddg=")
      assert r1.snippet =~ "process like any other Elixir process"

      assert r2.title == "GenServer - Mix & OTP"
      assert r2.rank == 2

      # the ranker unwraps the uddg redirector to the real destination
      assert Rank.canonical_url(r1.url) == "https://hexdocs.pm/elixir/GenServer.html"
    end
  end

  describe "parse/2 — Mojeek (direct urls)" do
    test "extracts direct https titles + snippets" do
      results = Engines.parse(:mojeek, fixture("mojeek.html"))

      assert length(results) == 2
      [r1, r2] = results

      assert r1.title == "GenServer — Elixir v1.19.5"
      assert r1.url == "https://hexdocs.pm/elixir/GenServer.html"
      assert r1.snippet =~ "keep state"

      assert r2.url == "https://www.erlang.org/doc/man/gen_server.html"
    end
  end

  test "parse/2 returns [] on a blocked/empty page rather than raising" do
    assert Engines.parse(:ddg, "<html><body>captcha</body></html>") == []
    assert Engines.parse(:mojeek, "") == []
  end
end
