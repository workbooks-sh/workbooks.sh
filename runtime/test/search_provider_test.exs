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
end
