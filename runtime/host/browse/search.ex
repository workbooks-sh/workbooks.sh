defmodule Workbooks.Browse.Search do
  @moduledoc """
  Keyless web search for the free in-engine browser — the 3w-style SERP adapters.
  Instead of only fetching URLs you already know, this QUERIES a search engine and
  parses the results page, so `Workbooks.Browse.search/2` works with zero keys and
  zero external service. DuckDuckGo's HTML endpoint is the primary (most
  scrape-stable); Brave and Bing are fallbacks if it returns nothing.

  Returns `[%{title, url, snippet}]`. Built on `Browse.Fetch` (so it inherits the
  TLS-fingerprinted, browser-headed GET) + lightweight HTML parsing.
  """
  alias Workbooks.Browse.{Extract, Fetch}

  @engines [:duckduckgo, :brave, :bing]

  @doc "Search `query` across engines (first non-empty wins). Opts: `:limit`, `:engine`."
  @spec query(String.t(), keyword()) :: [%{title: String.t(), url: String.t(), snippet: String.t() | nil}]
  def query(q, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    engine_opt = Keyword.get(opts, :engine)

    # DataForSEO first when credentialed (and no engine was forced): the keyless
    # scrape engines (ddg/brave/bing) return EMPTY from datacenter IPs — they
    # serve captchas to non-residential traffic, so on a fly box `web_search`
    # silently finds nothing (this stranded the lander even with a strong model).
    # DataForSEO is a real SERP API that works from a datacenter and $DATAFORSEO_AUTH
    # is already on the box; it is POST-only (the host does it; the agent's
    # GET-only fetch could not). Falls through to the scrape engines on absence/error.
    with nil <- engine_opt,
         auth when is_binary(auth) and auth != "" <- System.get_env("DATAFORSEO_AUTH"),
         [_ | _] = hits <- serp_dataforseo(q, auth, limit) do
      hits
    else
      _ -> query_scrape(q, limit, engine_opt)
    end
  end

  defp query_scrape(q, limit, engine_opt) do
    engines = case engine_opt do
      nil -> @engines
      e -> [e]
    end

    Enum.reduce_while(engines, [], fn engine, _ ->
      case fetch_serp(engine, q) do
        {:ok, html} ->
          results = parse(engine, html) |> Enum.take(limit)
          if results == [], do: {:cont, []}, else: {:halt, results}

        :error ->
          {:cont, []}
      end
    end)
  end

  # ── DataForSEO SERP (POST, basic auth; works from datacenter IPs) ────────────
  # $DATAFORSEO_AUTH is the base64 of "login:password" already → "Basic <auth>".
  defp serp_dataforseo(q, auth, limit) do
    body =
      Jason.encode!([
        %{keyword: q, location_code: 2840, language_code: "en", depth: max(limit, 10)}
      ])

    headers = [
      {~c"authorization", ~c"Basic #{auth}"},
      {~c"content-type", ~c"application/json"}
    ]

    url = ~c"https://api.dataforseo.com/v3/serp/google/organic/live/advanced"

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} -> parse_dataforseo(resp, limit)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp parse_dataforseo(resp, limit) do
    with {:ok, %{"tasks" => [%{"result" => [%{"items" => items} | _]} | _]}} <- Jason.decode(resp) do
      items
      |> Enum.filter(&(&1["type"] == "organic"))
      |> Enum.map(fn it ->
        %{title: it["title"] || "", url: it["url"] || "", snippet: it["description"]}
      end)
      |> Enum.reject(&(&1.url == ""))
      |> Enum.take(limit)
    else
      _ -> []
    end
  end

  # ── SERP fetch ──────────────────────────────────────────────────────────────
  defp fetch_serp(engine, q) do
    qs = URI.encode_www_form(q)
    url =
      case engine do
        :duckduckgo -> "https://html.duckduckgo.com/html/?q=#{qs}"
        :brave -> "https://search.brave.com/search?q=#{qs}"
        :bing -> "https://www.bing.com/search?q=#{qs}"
      end

    case Fetch.get(url, profile: :chrome) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      _ -> :error
    end
  end

  # ── SERP parse (per engine) ─────────────────────────────────────────────────
  defp parse(:duckduckgo, html) do
    titles =
      Regex.scan(~r/<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/si, html)
      |> Enum.map(fn [_, href, t] -> %{url: ddg_url(href), title: clean(t)} end)

    snippets =
      Regex.scan(~r/<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)<\/a>/si, html)
      |> Enum.map(fn [_, s] -> clean(s) end)

    zip(titles, snippets)
  end

  defp parse(_other, html) do
    # Generic fallback: real result anchors with visible text, off-host, deduped.
    Regex.scan(~r/<a[^>]+href="(https?:\/\/[^"]+)"[^>]*>([^<]{8,})<\/a>/si, html)
    |> Enum.map(fn [_, url, t] -> %{url: url, title: clean(t), snippet: nil} end)
    |> Enum.reject(&junk_host?(&1.url))
    |> Enum.uniq_by(& &1.url)
  end

  defp zip(titles, snippets) do
    titles
    |> Enum.with_index()
    |> Enum.map(fn {t, i} -> Map.put(t, :snippet, Enum.at(snippets, i)) end)
    |> Enum.reject(&(&1.url == "" or &1.title == ""))
  end

  # DuckDuckGo wraps result hrefs in a redirect: //duckduckgo.com/l/?uddg=<enc-url>
  defp ddg_url(href) do
    case Regex.run(~r/[?&]uddg=([^&]+)/, href) do
      [_, enc] -> URI.decode_www_form(enc)
      _ -> if String.starts_with?(href, "//"), do: "https:" <> href, else: href
    end
  end

  defp junk_host?(url) do
    host = URI.parse(url).host || ""
    Enum.any?(["bing.com", "microsoft.com", "duckduckgo.com", "brave.com", "go.microsoft"], &String.contains?(host, &1))
  end

  defp clean(s), do: s |> strip() |> String.trim()
  defp strip(s), do: s |> String.replace(~r/<[^>]+>/, "") |> Extract.decode_entities()
end
