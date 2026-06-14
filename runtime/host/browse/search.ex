defmodule Workbooks.Browse.Search do
  @moduledoc """
  Keyless web search for the free in-engine browser — the 3w-style SERP adapters.
  Instead of only fetching URLs you already know, this QUERIES a search engine and
  parses the results page, so `Workbooks.Browse.search/2` works with zero keys and
  zero external service.

  Engines are ROTATED (shuffled) per query so load spreads across providers — the
  failure mode is hammering ONE engine into a 429. (Proxy / IP rotation is a future
  cloud add-on; rotating WHICH service we call is the cheap win that needs no
  infra.) Empirically (2026-06-14) Brave serves real results to a headed GET while
  DuckDuckGo (html+lite) and Bing return 202/anomaly bot pages from flagged IPs —
  rotation still tries Brave (first non-empty wins) but doesn't hit it every time.
  Rate-limiting is tolerable as long as page-fetch still works; a headless browser
  tier (wb-70mi) is the durable answer.

  Returns `[%{title, url, snippet}]`. Built on `Browse.Fetch` (so it inherits the
  TLS-fingerprinted, browser-headed GET) + lightweight HTML parsing.
  """
  alias Workbooks.Browse.{Extract, Fetch}

  @engines [:brave, :duckduckgo, :bing]

  @doc """
  Search `query`. The PROVIDER is resolved from `opts[:provider]` → `$WB_SEARCH_PROVIDER`
  → `"keyless"`. Keyed providers (`exa`, `brave_api`) are more reliable than scraping
  but need the user's API key (`opts[:api_key]` or the provider's env key, settable in
  Settings) — on a missing key OR an empty/failed result they FALL BACK to the keyless
  scrape engines, so search always degrades to working. Opts: `:limit`, `:engine`,
  `:provider`, `:api_key`.
  """
  @spec query(String.t(), keyword()) :: [%{title: String.t(), url: String.t(), snippet: String.t() | nil}]
  def query(q, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    case provider(opts) do
      :exa -> keyed(q, limit, opts, "EXA_API_KEY", &exa/3)
      :brave_api -> keyed(q, limit, opts, "BRAVE_API_KEY", &brave_api/3)
      :perplexity -> keyed(q, limit, opts, "PERPLEXITY_API_KEY", &perplexity/3)
      :openrouter -> openrouter(q, limit, opts)
      :keyless -> query_scrape(q, limit, opts[:engine])
    end
  end

  @doc false
  def provider_for_test(opts), do: provider(opts)

  defp provider(opts) do
    raw = opts[:provider] || tenant_provider(opts[:tenant]) || System.get_env("WB_SEARCH_PROVIDER") || "keyless"

    case raw |> to_string() |> String.downcase() do
      "exa" -> :exa
      p when p in ["brave_api", "brave-api"] -> :brave_api
      "perplexity" -> :perplexity
      p when p in ["openrouter", "openrouter-web", "openrouter_web"] -> :openrouter
      _ -> :keyless
    end
  end

  # Per-tenant provider choice from the variable store (what Settings writes:
  # `wb var set wb.search.provider exa`). Plain (non-secret) var.
  defp tenant_provider(nil), do: nil

  defp tenant_provider(tenant) do
    case Workbooks.Vars.get(tenant, "wb.search.provider") do
      {:ok, p} when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  @doc false
  def tenant_secret_for_test(tenant, name), do: tenant_secret(tenant, name)

  # Per-tenant API key from the variable store (Settings stores it as a secret),
  # read host-side via ref(:host). nil when unset → caller falls back to env.
  defp tenant_secret(nil, _name), do: nil

  defp tenant_secret(tenant, name) do
    tmpl = "{{secret:#{name}}}"

    case Workbooks.Vars.ref(tenant, tmpl, :host) do
      ^tmpl -> nil
      val when is_binary(val) and val != "" -> val
      _ -> nil
    end
  end

  # Run a keyed provider; missing key OR empty/error → fall back to keyless scrape.
  defp keyed(q, limit, opts, key_env, fun) do
    case opts[:api_key] || tenant_secret(opts[:tenant], key_env) || System.get_env(key_env) do
      k when is_binary(k) and k != "" ->
        case fun.(q, k, limit) do
          [_ | _] = hits -> hits
          _ -> query_scrape(q, limit, opts[:engine])
        end

      _ ->
        query_scrape(q, limit, opts[:engine])
    end
  end

  # Exa (api.exa.ai) — POST /search, x-api-key → {results:[{title,url,text}]}.
  defp exa(q, key, limit) do
    body = Jason.encode!(%{query: q, numResults: limit, contents: %{text: %{maxCharacters: 400}}})

    headers = [
      {~c"x-api-key", String.to_charlist(key)},
      {~c"content-type", ~c"application/json"}
    ]

    post_json("https://api.exa.ai/search", headers, body, fn json ->
      (json["results"] || [])
      |> Enum.map(fn r -> %{title: r["title"] || "", url: r["url"] || "", snippet: r["text"]} end)
      |> Enum.reject(&(&1.url == ""))
      |> Enum.take(limit)
    end)
  end

  # Brave Search API — GET, X-Subscription-Token → {web:{results:[{title,url,description}]}}.
  defp brave_api(q, key, limit) do
    url = "https://api.search.brave.com/res/v1/web/search?q=#{URI.encode_www_form(q)}&count=#{limit}"

    headers = [
      {~c"x-subscription-token", String.to_charlist(key)},
      {~c"accept", ~c"application/json"}
    ]

    get_json(url, headers, fn json ->
      (get_in(json, ["web", "results"]) || [])
      |> Enum.map(fn r -> %{title: r["title"] || "", url: r["url"] || "", snippet: r["description"]} end)
      |> Enum.reject(&(&1.url == ""))
      |> Enum.take(limit)
    end)
  end

  # Perplexity (api.perplexity.ai) — a sonar model answers + returns its sources;
  # surfaced as results (search_results{title,url} when present, else citation URLs).
  defp perplexity(q, key, limit) do
    body = Jason.encode!(%{model: "sonar", messages: [%{role: "user", content: q}]})

    headers = [
      {~c"authorization", String.to_charlist("Bearer #{key}")},
      {~c"content-type", ~c"application/json"}
    ]

    post_json("https://api.perplexity.ai/chat/completions", headers, body, fn json ->
      cond do
        is_list(json["search_results"]) ->
          Enum.map(json["search_results"], fn r -> %{title: r["title"] || "", url: r["url"] || "", snippet: nil} end)

        is_list(json["citations"]) ->
          Enum.map(json["citations"], fn url -> %{title: to_string(url), url: to_string(url), snippet: nil} end)

        true ->
          []
      end
      |> Enum.reject(&(&1.url == ""))
      |> Enum.take(limit)
    end)
  end

  # OpenRouter web plugin — reuses the EXISTING OPENROUTER_API_KEY (no separate
  # key; the "default go-to-market" provider). The model runs a web search via the
  # `web` plugin and returns url_citation annotations, which we surface as results.
  defp openrouter(q, limit, opts) do
    key =
      opts[:api_key] || tenant_secret(opts[:tenant], "OPENROUTER_API_KEY") ||
        Workbooks.Secrets.get("OPENROUTER_API_KEY", System.get_env("OPENROUTER_API_KEY") || "")

    if is_binary(key) and key != "" do
      case openrouter_web(q, key, limit) do
        [_ | _] = hits -> hits
        _ -> query_scrape(q, limit, opts[:engine])
      end
    else
      query_scrape(q, limit, opts[:engine])
    end
  end

  defp openrouter_web(q, key, limit) do
    body =
      Jason.encode!(%{
        model: System.get_env("WB_SEARCH_OR_MODEL") || "openai/gpt-4o-mini",
        plugins: [%{id: "web", max_results: limit}],
        messages: [%{role: "user", content: "Search the web for: #{q}\nReturn the most relevant results."}]
      })

    headers = [
      {~c"authorization", String.to_charlist("Bearer #{key}")},
      {~c"content-type", ~c"application/json"}
    ]

    post_json("https://openrouter.ai/api/v1/chat/completions", headers, body, fn json ->
      (get_in(json, ["choices", Access.at(0), "message", "annotations"]) || [])
      |> Enum.filter(&(&1["type"] == "url_citation"))
      |> Enum.map(fn a ->
        c = a["url_citation"] || %{}
        %{title: c["title"] || "", url: c["url"] || "", snippet: c["content"]}
      end)
      |> Enum.reject(&(&1.url == ""))
      |> Enum.take(limit)
    end)
  end

  # Trusted FIXED API endpoints (not agent-supplied URLs → no SSRF surface).
  # LLM-backed providers (OpenRouter web plugin, Perplexity) run a model AND a
  # live web search server-side, so a single call legitimately takes 20-40s — a
  # 15s cap silently timed out and fell back to the (often-empty) keyless scrape.
  @post_timeout 45_000

  defp post_json(url, headers, body, parse) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", body}, [timeout: @post_timeout, connect_timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} -> decode_then(resp, parse)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp get_json(url, headers, parse) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} -> decode_then(resp, parse)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp decode_then(resp, parse) do
    case Jason.decode(resp) do
      {:ok, json} -> parse.(json)
      _ -> []
    end
  end

  defp query_scrape(q, limit, engine_opt) do
    Enum.reduce_while(engines_for(engine_opt), [], fn engine, _ ->
      case fetch_serp(engine, q) do
        {:ok, html} ->
          results = parse(engine, html) |> Enum.take(limit)
          if results == [], do: {:cont, []}, else: {:halt, results}

        :error ->
          {:cont, []}
      end
    end)
  end

  # Rotate providers per query (shuffle) → spread load, don't hammer one into a 429.
  # A forced `:engine` bypasses rotation (used by tests / targeted calls).
  defp engines_for(nil), do: Enum.shuffle(@engines)
  defp engines_for(engine), do: [engine]

  @doc false
  def engines_for_test(engine_opt), do: engines_for(engine_opt)

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
