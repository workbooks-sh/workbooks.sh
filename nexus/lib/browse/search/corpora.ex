defmodule Nexus.Browse.Search.Corpora do
  @moduledoc """
  **Open public-corpus engine adapters** for the keyless metasearch — the datacenter-reliable half.

  Where `Nexus.Browse.Search.Engines` scrapes anti-bot-hostile HTML SERPs (great from a residential
  IP, flaky from Fly), these adapters hit **open public APIs that return clean JSON with no API key
  and no captcha** — confirmed reachable from a datacenter IP (see `docs/SEARCH-ARCHITECTURE.md`):

    * `:wikipedia`   — `en.wikipedia.org/w/api.php` full-text search → article URLs.
    * `:hackernews`  — `hn.algolia.com/api/v1/search` stories → external URLs (the curated link graph).
    * `:openalex`    — `api.openalex.org/works` scholarly works → DOI/landing URLs.
    * `:archive`     — `archive.org/advancedsearch.php` Internet-Archive items.
    * `:commoncrawl` — `index.commoncrawl.org` open-web index → which pages exist on a domain
                       (host-scoped; the query is treated as a domain, falls back to a token).

  Each adapter is the SAME shape the keyless HTML engines expose — `build_url/2` + `parse/2` →
  `[%{title, url, snippet, source, rank}]` — so the metasearch fans out to corpora and HTML engines
  through one `Task.async_stream` and merges them in one `Nexus.Browse.Search.Rank.merge/1`. Parsing
  is pure JSON decode (`Jason`), best-effort: a blocked/garbage body yields `[]`, never raises.
  """

  @sources [:wikipedia, :hackernews, :openalex, :archive, :commoncrawl]

  @cc_index "CC-MAIN-2024-10"

  @doc "The open-corpus source names (datacenter-reliable, keyless)."
  def names, do: @sources

  @doc "Build the GET URL for `source` + `query`. `limit` caps rows where the API supports it."
  def build_url(source, query, limit \\ 10)

  def build_url(:wikipedia, query, limit) do
    "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=#{limit}&srsearch=" <>
      enc(query)
  end

  def build_url(:hackernews, query, limit) do
    "https://hn.algolia.com/api/v1/search?tags=story&hitsPerPage=#{limit}&query=" <> enc(query)
  end

  def build_url(:openalex, query, limit) do
    "https://api.openalex.org/works?per-page=#{limit}&search=" <> enc(query)
  end

  def build_url(:archive, query, limit) do
    "https://archive.org/advancedsearch.php?output=json&rows=#{limit}" <>
      "&fl[]=identifier&fl[]=title&fl[]=description&q=" <> enc(query)
  end

  def build_url(:commoncrawl, query, limit) do
    # CommonCrawl indexes pages by host. Treat the query as a domain if it looks like one,
    # else use its first token as a host-prefix wildcard — a best-effort "what exists on the web".
    domain = domain_of(query)
    "https://index.commoncrawl.org/#{@cc_index}-index?output=json&limit=#{limit}&url=" <>
      enc(domain <> "/*")
  end

  @doc """
  Parse a corpus API `body` into `[%{title, url, snippet, source, rank}]` (rank = 1-based). Returns
  `[]` on an undecodable/blocked body rather than raising.
  """
  def parse(source, body) when is_binary(body) do
    with {:ok, json} <- Jason.decode(body) do
      source
      |> rows(json)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, rank} -> Map.merge(r, %{source: source, rank: rank}) end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  def parse(_source, _), do: []

  # ── per-source row extraction ────────────────────────────────────────────────────────────────
  defp rows(:wikipedia, %{"query" => %{"search" => hits}}) when is_list(hits) do
    Enum.map(hits, fn h ->
      title = h["title"] || ""
      %{
        title: title,
        url: "https://en.wikipedia.org/wiki/" <> (title |> String.replace(" ", "_") |> enc()),
        snippet: strip_tags(h["snippet"] || "")
      }
    end)
  end

  defp rows(:hackernews, %{"hits" => hits}) when is_list(hits) do
    hits
    |> Enum.map(fn h ->
      story = "https://news.ycombinator.com/item?id=#{h["objectID"]}"
      %{
        title: h["title"] || h["story_title"] || "",
        # Prefer the linked external URL (the curated link graph); fall back to the HN discussion.
        url: present(h["url"]) || story,
        snippet: hn_snippet(h)
      }
    end)
    |> Enum.reject(&(&1.title == "" and &1.url == nil))
  end

  defp rows(:openalex, %{"results" => works}) when is_list(works) do
    Enum.map(works, fn w ->
      %{
        title: w["title"] || w["display_name"] || "",
        url: present(get_in(w, ["primary_location", "landing_page_url"])) || present(w["doi"]) ||
               "https://openalex.org/" <> Path.basename(w["id"] || ""),
        snippet: openalex_snippet(w)
      }
    end)
  end

  defp rows(:archive, %{"response" => %{"docs" => docs}}) when is_list(docs) do
    Enum.map(docs, fn d ->
      %{
        title: as_str(d["title"]),
        url: "https://archive.org/details/" <> (d["identifier"] || ""),
        snippet: as_str(d["description"])
      }
    end)
    |> Enum.reject(&(&1.url == "https://archive.org/details/"))
  end

  # CommonCrawl is newline-delimited JSON, not a JSON array — handled before Jason in parse/2.
  defp rows(:commoncrawl, _), do: []

  defp rows(_, _), do: []

  # CommonCrawl returns JSONL (one object per line), so override parse for it.
  def parse_commoncrawl(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode/1)
    |> Enum.flat_map(fn
      {:ok, %{"url" => url} = o} -> [%{title: url, url: url, snippet: "#{o["mime"]} #{o["timestamp"]}"}]
      _ -> []
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {r, rank} -> Map.merge(r, %{source: :commoncrawl, rank: rank}) end)
  rescue
    _ -> []
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────────────
  defp hn_snippet(h) do
    pts = h["points"]
    base = h["story_text"] || h["comment_text"] || ""
    ["#{pts && "#{pts} points"}", strip_tags(base)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")
  end

  defp openalex_snippet(w) do
    year = w["publication_year"]
    venue = get_in(w, ["primary_location", "source", "display_name"])
    [venue, year && to_string(year)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")
  end

  defp domain_of(query) do
    q = String.trim(query)
    cond do
      Regex.match?(~r/^[\w.-]+\.[a-z]{2,}$/i, q) -> q
      true -> (q |> String.split(~r/\s+/) |> List.first() || "example") <> ".com"
    end
  end

  defp strip_tags(s), do: s |> String.replace(~r/<[^>]+>/, "") |> String.replace(~r/\s+/, " ") |> String.trim()
  defp present(v) when is_binary(v) and v != "", do: v
  defp present(_), do: nil
  defp as_str(v) when is_binary(v), do: v
  defp as_str([h | _]), do: as_str(h)
  defp as_str(_), do: ""
  defp enc(s), do: URI.encode_www_form(to_string(s))
end
