defmodule Workbooks.SearchProviderTest do
  @moduledoc """
  Pins the pluggable search-provider seam (wb-vgga): provider resolves from
  opts → $WB_SEARCH_PROVIDER → keyless; a keyed provider with no key falls back to
  keyless (never crashes). The keyed APIs (Exa/Brave) need a real key to hit live —
  here we pin the routing/fallback, which is the architecture the user wanted to
  'work theoretically'.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Browse.Search

  setup do
    prev = System.get_env("WB_SEARCH_PROVIDER")
    on_exit(fn -> if prev, do: System.put_env("WB_SEARCH_PROVIDER", prev), else: System.delete_env("WB_SEARCH_PROVIDER") end)
    :ok
  end

  test "provider resolves from opts (exa / brave_api / brave-api), unknown → keyless" do
    assert Search.provider_for_test([]) == :keyless
    assert Search.provider_for_test(provider: "exa") == :exa
    assert Search.provider_for_test(provider: "brave_api") == :brave_api
    assert Search.provider_for_test(provider: "brave-api") == :brave_api
    assert Search.provider_for_test(provider: "perplexity") == :perplexity
    assert Search.provider_for_test(provider: "openrouter") == :openrouter
    assert Search.provider_for_test(provider: "openrouter-web") == :openrouter
    assert Search.provider_for_test(provider: "totally-bogus") == :keyless
  end

  test "WB_SEARCH_PROVIDER env selects the provider when no opt given" do
    System.put_env("WB_SEARCH_PROVIDER", "exa")
    assert Search.provider_for_test([]) == :exa
  end

  test "a keyed provider with NO key falls back to keyless — returns a list, never crashes" do
    assert is_list(Search.query("test query", provider: :exa, api_key: nil, limit: 1))
  end

  test "per-tenant provider comes from Vars (Settings); explicit opt overrides; unset → keyless" do
    t = "sp-test-#{System.unique_integer([:positive])}"
    Workbooks.Vars.set(t, "wb.search.provider", "openrouter")
    assert Search.provider_for_test(tenant: t) == :openrouter
    assert Search.provider_for_test(tenant: "sp-unset-#{System.unique_integer([:positive])}") == :keyless
    assert Search.provider_for_test(tenant: t, provider: "exa") == :exa
  end

  test "per-tenant API key resolves from a Vars secret (host-readable); unset → nil → env fallback" do
    t = "spk-#{System.unique_integer([:positive])}"
    Workbooks.Vars.set(t, "EXA_API_KEY", "sk-tenant-xyz", true)
    assert Search.tenant_secret_for_test(t, "EXA_API_KEY") == "sk-tenant-xyz"
    assert Search.tenant_secret_for_test("spk-unset-#{System.unique_integer([:positive])}", "EXA_API_KEY") == nil
    assert Search.tenant_secret_for_test(nil, "EXA_API_KEY") == nil
  end

  # Regression: the /api/browse/search endpoint once read conn.params["q"]
  # WITHOUT fetch_query_params, so q was always nil → "" → every search returned
  # [] silently. parse_request/2 is the pure, pinned param-handling.
  test "parse_request reads q (trimmed), threads tenant, honors a provider override" do
    {q, opts} = Search.parse_request(%{"q" => "  elixir lang  ", "limit" => "5", "provider" => "exa"}, "tnt1")
    assert q == "elixir lang"
    assert opts[:limit] == 5
    assert opts[:tenant] == "tnt1"
    assert opts[:provider] == "exa"
  end

  test "parse_request: missing q → \"\", non-numeric/over-cap limit → safe default 8 (never crashes)" do
    assert {"", opts} = Search.parse_request(%{}, nil)
    assert opts[:limit] == 8
    assert opts[:tenant] == nil
    assert {"x", o2} = Search.parse_request(%{"q" => "x", "limit" => "abc"}, nil)
    assert o2[:limit] == 8
    assert {"x", o3} = Search.parse_request(%{"q" => "x", "limit" => "9999"}, nil)
    assert o3[:limit] == 8
  end

  test "parse_request: no provider param → no :provider opt (tenant/env/keyless decides)" do
    {_q, opts} = Search.parse_request(%{"q" => "x"}, "t")
    refute Keyword.has_key?(opts, :provider)
    {_q2, opts2} = Search.parse_request(%{"q" => "x", "provider" => ""}, "t")
    refute Keyword.has_key?(opts2, :provider)
  end
end
