defmodule Workbooks.Browse.Native do
  @moduledoc """
  The default, free, in-engine Browse provider: pure-BEAM `:ssl`-fingerprinted
  fetch (`Workbooks.Browse.Fetch`), lightweight HTML→org extraction
  (`Workbooks.Browse.Extract`), and concurrent crawl (`Workbooks.Browse.Crawl`).
  No keys, no external service. Does NOT implement `:search` (no search index of
  its own) — that capability is left to a pluggable provider like Exa/Perplexity.

  Honours a `:proxy` option (a `{host, port}` tuple or a 0-arity fun returning
  one) so a rotating-proxy service can be layered on without touching callers.
  """
  @behaviour Workbooks.Browse.Provider
  alias Workbooks.Browse.{Crawl, Extract, Fetch, Search}

  @impl true
  def capabilities, do: [:fetch, :crawl, :search]

  @impl true
  def search(query, opts \\ []), do: {:ok, Search.query(query, opts)}

  @impl true
  def fetch(url, opts \\ []) do
    case Fetch.get(url, with_proxy(opts)) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, Extract.parse(body, url)}
      {:ok, %{status: s}} -> {:error, {:http_status, s}}
      {:error, _} = e -> e
    end
  end

  @impl true
  def crawl(seed, opts \\ [])
  def crawl(urls, opts) when is_list(urls), do: {:ok, Crawl.pages(urls, with_proxy(opts))}
  def crawl(seed, opts) when is_binary(seed), do: {:ok, Crawl.site(seed, with_proxy(opts))}

  # Resolve a possibly-rotating proxy into a concrete value for this call.
  defp with_proxy(opts) do
    case Keyword.get(opts, :proxy) do
      fun when is_function(fun, 0) -> Keyword.put(opts, :proxy, fun.())
      _ -> opts
    end
  end
end
