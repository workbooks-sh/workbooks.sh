defmodule Workbooks.Browse.Crawl do
  @moduledoc """
  Concurrent crawl — the third brick of the runtime's browse capability, and the
  one that plays to BEAM's strengths: fan out fetch+extract across many URLs with
  bounded concurrency via `Task.async_stream`, no thread pool, no sidecar. Two
  entry points:

    * `pages/2` — fetch+extract a known URL list concurrently.
    * `site/2`  — BFS a seed: follow same-host links up to `:max_pages`/`:depth`.

  Both return `[Workbooks.Browse.Extract.page()]`; `to_org/1` concatenates them
  into one org context-repository document. Failures are dropped (a dead URL
  doesn't sink the crawl), so the result is "everything that came back."
  """
  alias Workbooks.Browse.{Extract, Fetch}

  @max_concurrency 8
  @task_timeout 25_000

  @doc "Fetch+extract each URL concurrently. Opts: `:profile`, `:max_concurrency`."
  @spec pages([String.t()], keyword()) :: [Extract.page()]
  def pages(urls, opts \\ []) do
    profile = Keyword.get(opts, :profile, :chrome)
    conc = Keyword.get(opts, :max_concurrency, @max_concurrency)

    urls
    |> Enum.uniq()
    |> Task.async_stream(
      fn url -> fetch_one(url, profile) end,
      max_concurrency: conc,
      timeout: @task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, page}} -> [page]
      _ -> []
    end)
  end

  @doc """
  BFS-crawl a seed, following same-host links. Opts: `:max_pages` (default 25),
  `:depth` (default 2), `:profile`, `:max_concurrency`.
  """
  @spec site(String.t(), keyword()) :: [Extract.page()]
  def site(seed, opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, 25)
    depth = Keyword.get(opts, :depth, 2)
    host = URI.parse(seed).host
    bfs([seed], MapSet.new(), [], host, depth, max_pages, opts)
  end

  @spec to_org([Extract.page()]) :: String.t()
  def to_org(pages) do
    header = "#+TITLE: browse crawl — #{length(pages)} pages\n"
    header <> Enum.map_join(pages, "\n\n", &Extract.to_org/1)
  end

  # ── BFS ─────────────────────────────────────────────────────────────────────
  defp bfs(_frontier, _seen, acc, _host, _depth, max, _opts) when length(acc) >= max,
    do: Enum.take(acc, max)

  defp bfs([], _seen, acc, _host, _depth, _max, _opts), do: acc
  defp bfs(_frontier, _seen, acc, _host, 0, _max, _opts), do: acc

  defp bfs(frontier, seen, acc, host, depth, max, opts) do
    todo = Enum.reject(frontier, &MapSet.member?(seen, &1)) |> Enum.take(max - length(acc))
    seen = Enum.reduce(todo, seen, &MapSet.put(&2, &1))
    got = pages(todo, opts)

    next =
      got
      |> Enum.flat_map(& &1.links)
      |> Enum.map(& &1.href)
      |> Enum.filter(&(URI.parse(&1).host == host))
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()

    bfs(next, seen, acc ++ got, host, depth - 1, max, opts)
  end

  defp fetch_one(url, profile) do
    case Fetch.get(url, profile: profile) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, Extract.parse(body, url)}
      _ -> :error
    end
  end
end
