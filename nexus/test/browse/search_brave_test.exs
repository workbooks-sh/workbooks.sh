defmodule Nexus.Browse.Search.BraveTest do
  use ExUnit.Case, async: true

  alias Nexus.Browse.Search.Brave

  @json %{
    "web" => %{
      "results" => [
        %{
          "title" => "GenServer — Elixir",
          "url" => "https://hexdocs.pm/elixir/GenServer.html",
          "description" => "A <strong>GenServer</strong> is a process like any other Elixir process."
        },
        %{
          "title" => "gen_server",
          "url" => "https://www.erlang.org/doc/man/gen_server.html",
          "description" => "Behaviour module for the server of a client-server relation."
        }
      ]
    }
  }

  test "parse/1 maps web.results to the shared shape and strips tags" do
    [r1, r2] = Brave.parse(@json)
    assert r1.title == "GenServer — Elixir"
    assert r1.url == "https://hexdocs.pm/elixir/GenServer.html"
    assert r1.snippet == "A GenServer is a process like any other Elixir process."
    assert r2.url == "https://www.erlang.org/doc/man/gen_server.html"
  end

  test "parse/1 tolerates a missing web key" do
    assert Brave.parse(%{}) == []
  end

  test "search/2 uses an injected fetch fun (no network, no key needed)" do
    System.put_env("BRAVE_API_KEY", "test-token")

    fetch = fn url, headers ->
      assert String.starts_with?(url, "https://api.search.brave.com/res/v1/web/search?")
      assert {"X-Subscription-Token", "test-token"} in headers
      {:ok, @json}
    end

    assert {:ok, results} = Brave.search("gen server", fetch: fetch, limit: 5)
    assert length(results) == 2
    assert hd(results).title == "GenServer — Elixir"
  after
    System.delete_env("BRAVE_API_KEY")
  end

  test "search/2 errors without a key" do
    System.delete_env("BRAVE_API_KEY")
    assert Brave.search("x") == {:error, :missing_brave_api_key}
  end

  test "search/2 rejects an empty query" do
    System.put_env("BRAVE_API_KEY", "k")
    assert Brave.search("   ") == {:error, :empty_query}
  after
    System.delete_env("BRAVE_API_KEY")
  end
end
