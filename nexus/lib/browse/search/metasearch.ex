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
  default; cloud deployments should set `<work-deploy search="brave">` (a keyed API, reliable from any
  IP) — the documented prior "empty search" failure mode.
  """
  @behaviour Nexus.Browse

  alias Nexus.Browse.Search.{Engines, Rank}

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
      engines = engines(opts)
      limit = opts[:limit] || @top_n

      lists =
        engines
        |> Task.async_stream(
          fn engine -> {engine, fetch_engine(engine, query)} end,
          max_concurrency: max(length(engines), 1),
          timeout: @per_engine_timeout + 1_000,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, {engine, results}} -> [{engine, results}]
          # a killed/crashed engine task → drop it (best-effort)
          _ -> []
        end)

      merged =
        lists
        |> Rank.merge()
        |> Enum.take(limit)
        |> Enum.map(&Map.take(&1, [:title, :url, :snippet]))

      {:ok, merged}
    end
  end

  defp engines(opts) do
    case opts[:engines] || configured_engines() do
      [] -> @default_engines
      list -> list
    end
  end

  defp configured_engines do
    known = MapSet.new(Engines.names())

    Nexus.Config.search_engines()
    |> Enum.map(&normalize_name/1)
    |> Enum.filter(&MapSet.member?(known, &1))
  end

  defp normalize_name("duckduckgo"), do: :ddg
  defp normalize_name("ddg"), do: :ddg
  defp normalize_name(name) when is_binary(name), do: String.to_atom(name)
  defp normalize_name(name) when is_atom(name), do: name

  # One engine: build URL → host-brokered GET → parse. Any failure → []. Never raises out.
  defp fetch_engine(engine, query) do
    url = Engines.build_url(engine, query)

    case Nexus.Dock.fetch(url) do
      body when is_binary(body) and body != "" -> Engines.parse(engine, body)
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
