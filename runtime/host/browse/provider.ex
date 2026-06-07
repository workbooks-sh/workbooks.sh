defmodule Workbooks.Browse.Provider do
  @moduledoc """
  The extensible slot for `Workbooks.Browse`. Browse ships a free, in-engine
  default (`Workbooks.Browse.Native` — `:ssl` fetch + Floki-lite extract +
  concurrent crawl), but the native browser can't do everything (heavy JS,
  bot-walls, real web search). So Browse is provider-pluggable: a deployment can
  drop in Exa, Firecrawl, context.dev, Perplexity, etc. for any capability the
  vanilla browser doesn't cover — without brandnana or any caller changing.

  A provider implements whatever it can and declares it via `capabilities/0`;
  the dispatcher routes each call to the configured provider for that capability,
  falling back to Native. Proxy rotation is orthogonal — a `:proxy` option (a
  `{host, port}` or a 0-arity fun returning one) threads through to providers
  that fetch, so a rotating-proxy service turns the vanilla browser into a fuller
  scraper. Both the provider choice and the proxy are deploy-kit knobs.
  """

  @type url :: String.t()
  @type page :: Workbooks.Browse.Extract.page()
  @type result :: %{title: String.t() | nil, url: url(), snippet: String.t() | nil}

  @doc "Which capabilities this provider implements: subset of [:fetch, :crawl, :search]."
  @callback capabilities() :: [:fetch | :crawl | :search]

  @doc "Fetch+extract a single URL."
  @callback fetch(url(), keyword()) :: {:ok, page()} | {:error, term()}

  @doc "Crawl a seed URL or a list of URLs into pages."
  @callback crawl(url() | [url()], keyword()) :: {:ok, [page()]} | {:error, term()}

  @doc "Web search for a query → ranked results."
  @callback search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}

  @optional_callbacks fetch: 2, crawl: 2, search: 2
end
