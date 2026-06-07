defmodule Workbooks.Browse.Firecrawl do
  @moduledoc """
  Example external Browse provider — proves the slot. Firecrawl renders JS and
  defeats bot-walls the free in-engine browser can't, so a deployment that needs
  heavy-SPA scraping or real web search plugs this in:

      config :workbooks, :browse, provider: Workbooks.Browse.Firecrawl

  …and every `Workbooks.Browse.fetch/crawl/search` call routes here instead of
  Native — no caller (incl. brandnana harvest) changes. Needs `FIRECRAWL_API_KEY`.
  Implements `:fetch` (/v1/scrape, returns rendered HTML → the same
  `Browse.Extract.page` shape) and `:search` (/v1/search). Crawl falls back to
  Native's concurrent fan-out over Firecrawl-fetched pages.
  """
  @behaviour Workbooks.Browse.Provider
  alias Workbooks.Browse.Extract

  @base "https://api.firecrawl.dev/v1"
  @timeout 60_000

  @impl true
  def capabilities, do: [:fetch, :crawl, :search]

  @impl true
  def fetch(url, _opts \\ []) do
    body = Jason.encode!(%{url: url, formats: ["html"], onlyMainContent: false})

    case post("/scrape", body) do
      {:ok, %{"data" => %{"html" => html}}} when is_binary(html) -> {:ok, Extract.parse(html, url)}
      {:ok, other} -> {:error, {:firecrawl_unexpected, Map.get(other, "error", other)}}
      {:error, _} = e -> e
    end
  end

  @impl true
  def crawl(seed, opts \\ [])
  def crawl(urls, opts) when is_list(urls),
    do: {:ok, urls |> Enum.uniq() |> fetch_many(opts)}

  def crawl(seed, opts) when is_binary(seed) do
    # Use Native's BFS to discover same-host links, but Firecrawl-render each page.
    case fetch(seed, opts) do
      {:ok, page} ->
        host = URI.parse(seed).host
        next = page.links |> Enum.map(& &1.href) |> Enum.filter(&(URI.parse(&1).host == host))
        urls = [seed | Enum.take(Enum.uniq(next), Keyword.get(opts, :max_pages, 25) - 1)]
        {:ok, fetch_many(urls, opts)}

      e ->
        e
    end
  end

  @impl true
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    body = Jason.encode!(%{query: query, limit: limit})

    case post("/search", body) do
      {:ok, %{"data" => results}} when is_list(results) ->
        {:ok,
         Enum.map(results, fn r ->
           %{title: r["title"], url: r["url"], snippet: r["description"]}
         end)}

      {:ok, other} ->
        {:error, {:firecrawl_unexpected, Map.get(other, "error", other)}}

      {:error, _} = e ->
        e
    end
  end

  # ── HTTP ────────────────────────────────────────────────────────────────────
  defp fetch_many(urls, _opts) do
    urls
    |> Task.async_stream(&fetch/1, max_concurrency: 4, timeout: @timeout, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {:ok, page}} -> [page]
      _ -> []
    end)
  end

  defp post(path, body) do
    :inets.start()
    :ssl.start()
    key = System.get_env("FIRECRAWL_API_KEY") || ""
    headers = [{~c"authorization", ~c"Bearer #{key}"}]
    req = {String.to_charlist(@base <> path), headers, ~c"application/json", body}

    case :httpc.request(:post, req, [timeout: @timeout, connect_timeout: 20_000], body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} when status in 200..299 -> {:ok, Jason.decode!(resp)}
      {:ok, {{_, status, _}, _h, resp}} -> {:error, {:http_status, status, String.slice(resp, 0, 200)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
