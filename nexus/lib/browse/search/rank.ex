defmodule Nexus.Browse.Search.Rank do
  @moduledoc """
  The engine-independent aggregation core of the keyless metasearch — pure functions, no network.

  Given per-engine result lists (each a `[%{title, url, snippet, rank}]`, `rank` 1-based position on
  that engine), it:

    * **Canonicalizes** each URL — unwraps the DuckDuckGo `uddg=` redirector, strips tracking params
      (`utm_*`, `fbclid`, …), drops the fragment, normalizes the scheme/host/trailing slash — so the
      same destination compares equal regardless of how an engine wrapped it.
    * **Dedupes by canonical URL**, keeping the best (longest) title + snippet seen and recording the
      set of engines that surfaced it (provenance for the agent).
    * **Reciprocal-rank fusion**: score = Σ over engines `weight · 1 / position`, with a small bonus
      for cross-engine agreement. Sorts descending.

  This is the only "smart" part of the metasearch and is unit-tested with plain data.
  """

  @agreement_bonus 0.10
  @strip_params ~w(utm_source utm_medium utm_campaign utm_term utm_content fbclid gclid msclkid ref ref_src)

  @type result :: %{title: String.t(), url: String.t(), snippet: String.t(), rank: pos_integer}

  @doc """
  Merge per-engine result lists into one ranked, deduped list of `%{title, url, snippet, score,
  engines}`. `engine_lists` is a list of `{engine_name, results}` tuples; `weights` maps an engine
  name to a float weight (default 1.0).
  """
  @spec merge([{atom | String.t(), [result]}], map) :: [map]
  def merge(engine_lists, weights \\ %{}) do
    engine_lists
    |> Enum.flat_map(fn {engine, results} ->
      Enum.map(results, fn r -> {engine, normalize(r)} end)
    end)
    |> Enum.reject(fn {_e, r} -> r.url == nil end)
    |> Enum.reduce(%{}, fn {engine, r}, acc ->
      key = r.url
      w = Map.get(weights, engine, 1.0)
      contribution = w * 1.0 / r.rank

      Map.update(acc, key, new_record(r, engine, contribution), fn rec ->
        %{
          rec
          | score: rec.score + contribution,
            engines: MapSet.put(rec.engines, engine),
            title: better(rec.title, r.title),
            snippet: better(rec.snippet, r.snippet)
        }
      end)
    end)
    |> Map.values()
    |> Enum.map(fn rec ->
      n = MapSet.size(rec.engines)
      score = rec.score + (n - 1) * @agreement_bonus

      %{
        title: rec.title,
        url: rec.url,
        snippet: rec.snippet,
        score: Float.round(score, 4),
        engines: rec.engines |> MapSet.to_list() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc "Dedupe a single merged result list by canonical URL (keeps first occurrence). Pure."
  @spec dedupe([result]) :: [result]
  def dedupe(results) do
    results
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1.url == nil))
    |> Enum.reduce({[], MapSet.new()}, fn r, {acc, seen} ->
      if MapSet.member?(seen, r.url),
        do: {acc, seen},
        else: {[r | acc], MapSet.put(seen, r.url)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp new_record(r, engine, contribution) do
    %{
      url: r.url,
      title: r.title,
      snippet: r.snippet,
      score: contribution,
      engines: MapSet.new([engine])
    }
  end

  defp better(a, b) do
    a = a || ""
    b = b || ""
    if String.length(b) > String.length(a), do: b, else: a
  end

  @doc """
  Canonicalize one result map: unwrap redirectors + strip tracking params + normalize. Returns the
  map with `:url` set to the canonical form (or `nil` if it can't be canonicalized) and `:rank`
  defaulted to a high number when absent.
  """
  @spec normalize(map) :: map
  def normalize(r) do
    r
    |> Map.put_new(:rank, 99)
    |> Map.put_new(:title, "")
    |> Map.put_new(:snippet, "")
    |> Map.update(:url, nil, &canonical_url/1)
    |> Map.update!(:title, &collapse/1)
    |> Map.update!(:snippet, &collapse/1)
  end

  @doc "Canonicalize a URL string → a stable comparison key, or nil if unusable."
  @spec canonical_url(String.t() | nil) :: String.t() | nil
  def canonical_url(nil), do: nil

  def canonical_url(url) when is_binary(url) do
    url = unwrap(String.trim(url))
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> nil
      uri.host in [nil, ""] -> nil
      true -> rebuild(uri)
    end
  rescue
    _ -> nil
  end

  # Unwrap a redirector: DDG (`//duckduckgo.com/l/?uddg=…`), and the generic `?url=`/`?u=` pattern.
  defp unwrap(url) do
    url = if String.starts_with?(url, "//"), do: "https:" <> url, else: url

    case URI.parse(url) do
      %URI{host: h, query: q} when is_binary(q) and h != nil ->
        params = URI.decode_query(q)

        target =
          (String.contains?(h, "duckduckgo.com") && params["uddg"]) ||
            params["url"] || params["u"]

        if is_binary(target) and String.starts_with?(target, "http"), do: target, else: url

      _ ->
        url
    end
  end

  defp rebuild(uri) do
    host = uri.host |> String.downcase() |> String.replace_prefix("www.", "")

    query =
      case uri.query do
        nil ->
          nil

        q ->
          kept =
            q
            |> URI.decode_query()
            |> Enum.reject(fn {k, _} -> k in @strip_params end)
            |> Enum.sort()

          if kept == [], do: nil, else: URI.encode_query(kept)
      end

    path = (uri.path || "/") |> String.replace_suffix("/", "") |> default_path()

    %URI{scheme: "https", host: host, path: path, query: query}
    |> URI.to_string()
  end

  defp default_path(""), do: "/"
  defp default_path(p), do: p

  defp collapse(s) when is_binary(s) do
    s |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp collapse(_), do: ""
end
