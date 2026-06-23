defmodule Nexus.Browse.Search.Metasearch do
  @moduledoc """
  The **keyless default** `:search` provider — a pure-BEAM metasearch aggregator (the SearXNG model,
  reimplemented over our own pieces; see `docs/SEARCH-ARCHITECTURE.md`).

  For each query it fans out concurrently (`Task.async_stream`, bounded, per-engine timeout) across
  the configured keyless engines (`Nexus.Config.search_engines/0`, default DuckDuckGo-HTML + Mojeek +
  Startpage), fetches each results page through `Nexus.Dock.fetch` (SSRF-safe GET, with the
  curl-impersonate escalation baked into `Nexus.Compilers.Shared.http_get`), parses it with
  `Nexus.Browse.Search.Engines`, and merges everything via `Nexus.Browse.Search.Rank` (canonicalize +
  dedupe-by-URL + reciprocal-rank fusion). Returns the top-N `%{title, url, snippet}`.

  **Best-effort:** a slow/blocked/empty engine is dropped (its `Task` times out or yields `[]`) — one
  engine 429-ing never stalls or fails the result, as long as another answers.

  **Reliability note:** keyless scraping works great from a residential/dev IP but is anti-bot-hostile
  from datacenter IPs (Google/Bing/Brave degrade to CAPTCHA/403 on Fly). This is the LOCAL/dev
  default; cloud deployments should set `deploy search="brave"` (a keyed API, reliable from any
  IP) — the documented prior "empty search" failure mode.
  """
  @behaviour Nexus.Browse

  alias Nexus.Browse.Search.{Corpora, Engines, Rank, Semantic}

  @default_engines [:ddg, :mojeek, :startpage]
  @per_engine_timeout 8_000
  @top_n 10

  @impl true
  def capabilities, do: [:search]

  @impl true
  def search(query, opts \\ []) do
    query = String.trim(query || "")

    if query == "" do
      {:error, :empty_query}
    else
      sources = sources(opts)
      limit = opts[:limit] || @top_n

      lists =
        sources
        |> Task.async_stream(
          fn source -> {source, fetch_source(source, query, limit)} end,
          max_concurrency: max(length(sources), 1),
          timeout: @per_engine_timeout + 1_000,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, {source, results}} -> [{source, results}]
          # a killed/crashed source task → drop it (best-effort)
          _ -> []
        end)

      merged = Rank.merge(lists)

      ranked =
        if opts[:semantic] == false do
          merged
        else
          Semantic.rerank(query, merged, opts)
        end

      out =
        ranked
        |> Enum.take(limit)
        |> Enum.map(&Map.take(&1, [:title, :url, :snippet, :score, :engines, :semantic]))

      {:ok, out}
    end
  end

  # The full fan-out source set: keyless HTML engines + open-corpus APIs. The corpora set is
  # datacenter-reliable and usable standalone — `opts[:sources]` (or `engines="…"` / `corpora="…"`
  # config) can restrict to e.g. only corpora when the HTML engines get blocked on Fly.
  defp sources(opts) do
    cond do
      opts[:sources] -> opts[:sources]
      opts[:engines] -> opts[:engines]
      true -> default_sources()
    end
  end

  defp default_sources do
    engines =
      case configured_engines() do
        [] -> @default_engines
        list -> list
      end

    engines ++ Corpora.names()
  end

  defp configured_engines do
    known = MapSet.new(Engines.names())

    Nexus.Config.search_engines()
    |> Enum.map(&normalize_name/1)
    |> Enum.filter(&MapSet.member?(known, &1))
  end

  defp normalize_name("duckduckgo"), do: :ddg
  defp normalize_name("ddg"), do: :ddg
  # Only EXISTING atoms — an unknown/attacker-supplied engine name must not mint a new atom (the
  # global, non-GC'd, ~1M-cap atom table is shared by every tenant: minting from request input is an
  # exhaustion-DoS primitive, wb-m73h). A name with no existing atom can't be a known engine anyway,
  # so it resolves to a sentinel the downstream `known` filter drops.
  defp normalize_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :__unknown_engine__
  end

  defp normalize_name(name) when is_atom(name), do: name

  # One source: build URL → host-brokered GET → parse. Routes to the HTML-engine adapter or the
  # open-corpus adapter by source name. Any failure → []. Never raises out.
  defp fetch_source(source, query, limit) do
    cond do
      source in Corpora.names() -> fetch_corpus(source, query, limit)
      true -> fetch_engine(source, query)
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp fetch_engine(engine, query) do
    url = Engines.build_url(engine, query)

    case Nexus.Dock.fetch(url) do
      body when is_binary(body) and body != "" -> Engines.parse(engine, body)
      _ -> []
    end
  end

  defp fetch_corpus(source, query, limit) do
    url = Corpora.build_url(source, query, limit)

    case Nexus.Dock.fetch(url) do
      body when is_binary(body) and body != "" ->
        # CommonCrawl is JSONL, not a JSON array — its own parser.
        if source == :commoncrawl, do: Corpora.parse_commoncrawl(body), else: Corpora.parse(source, body)

      _ ->
        []
    end
  end
end
