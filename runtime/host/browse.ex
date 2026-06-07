defmodule Workbooks.Browse do
  @moduledoc """
  The runtime's web capability — a general Workbooks primitive, NOT a brandnana
  feature (brandnana's `harvest` is the brand-specific consumer; it calls Browse).
  Anything running in Workbooks can browse for free via the in-engine default.

  Browse is a thin DISPATCHER over a pluggable provider slot
  (`Workbooks.Browse.Provider`). Each capability — `:fetch`, `:crawl`, `:search`
  — routes to the configured provider for that capability, falling back to the
  free native browser (`Workbooks.Browse.Native`). So a deployment can keep the
  vanilla browser, swap in Exa/Firecrawl/context.dev/Perplexity for the bits the
  native browser can't do (heavy JS, real search), and/or attach a rotating
  proxy — all via config, no caller changes.

      config :workbooks, :browse,
        provider: Workbooks.Browse.Native,            # default for fetch/crawl
        search_provider: Workbooks.Browse.Exa,        # optional: real web search
        proxy: nil                                    # {host, port} | (-> {host, port})

  These are the deploy-kit knobs: pick a browsing service, add proxy rotation.
  """
  alias Workbooks.Browse.Native

  @doc "Fetch+extract one URL via the configured fetch provider."
  def fetch(url, opts \\ []), do: provider(:fetch).fetch(url, merge_proxy(opts))

  @doc "Crawl a seed URL or URL list via the configured crawl provider."
  def crawl(seed, opts \\ []), do: provider(:crawl).crawl(seed, merge_proxy(opts))

  @doc "Web search via the configured search provider (no native default → error if unset)."
  def search(query, opts \\ []) do
    case provider(:search) do
      nil -> {:error, :no_search_provider}
      mod -> mod.search(query, opts)
    end
  end

  @doc "Resolve the provider module for a capability (nil if none + native can't)."
  def provider(capability) do
    cfg = Application.get_env(:workbooks, :browse, [])

    explicit =
      case capability do
        :search -> cfg[:search_provider]
        _ -> nil
      end

    cond do
      explicit -> explicit
      provides?(cfg[:provider], capability) -> cfg[:provider]
      provides?(Native, capability) -> Native
      true -> nil
    end
  end

  defp provides?(nil, _), do: false
  defp provides?(mod, cap) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :capabilities, 0) and cap in mod.capabilities()
  end

  # Inject the configured proxy unless the caller already set one.
  defp merge_proxy(opts) do
    case Application.get_env(:workbooks, :browse, [])[:proxy] do
      nil -> opts
      proxy -> Keyword.put_new(opts, :proxy, proxy)
    end
  end
end
