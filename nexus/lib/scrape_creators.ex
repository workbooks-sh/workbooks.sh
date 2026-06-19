defmodule Nexus.ScrapeCreators do
  @moduledoc """
  The ONE external dependency brandnana genuinely needs: ad + social **creative** data. We can't get
  this natively — Meta's Ad Library UI is JS-rendered + bot-walled (our Blitz renderer runs no full JS
  loop), and Meta's official Ad Library API only covers political/issue ads, not a brand's commercial
  creatives. So this is an optional, **keyed** capability (`SCRAPECREATORS_API_KEY`) that degrades
  gracefully: with no key, `ads/2` and `social/2` return `[]` and the brand book simply omits those
  sections — everything else stays native + free.

  ScrapeCreators is a plain JSON API (`https://api.scrapecreators.com`, `x-api-key` header). Parsing
  JSON here is the legitimate network-boundary exception. The endpoint paths reflect ScrapeCreators'
  documented surface; verify them against your account when you wire in a key (the parser is defensive,
  so a shape change degrades to `[]` rather than crashing).
  """

  @base "https://api.scrapecreators.com"

  @doc "Is a ScrapeCreators key present? (else ad/social data is simply unavailable)"
  def configured?, do: key() not in [nil, ""]
  defp key, do: Nexus.Secrets.get("SCRAPECREATORS_API_KEY")

  @doc "Ad creatives for a brand domain (Meta Ad Library). `[%{platform, image, text, link}]` or `[]`."
  def ads(domain, opts \\ []) do
    limit = opts[:limit] || 8

    with true <- configured?(),
         {:ok, page} <- company(domain),
         {:ok, body} <- get("/v1/facebook/adLibrary/company/ads", %{pageId: page, trim: "true"}) do
      body
      |> dig(["results", "ads"])
      |> Enum.take(limit)
      |> Enum.map(&normalize_ad/1)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  @doc "Organic social posts for a brand handle/domain. `[%{platform, image, text, link}]` or `[]`."
  def social(handle, opts \\ []) do
    limit = opts[:limit] || 8

    with true <- configured?(),
         {:ok, body} <- get("/v1/instagram/posts", %{handle: strip_handle(handle)}) do
      body
      |> dig(["posts", "items"])
      |> Enum.take(limit)
      |> Enum.map(&normalize_social/1)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # Resolve a domain → a Meta advertiser page id (the handle the ad endpoint needs).
  defp company(domain) do
    with {:ok, body} <- get("/v1/facebook/adLibrary/search/companies", %{query: domain}) do
      case dig(body, ["searchResults", "companies"]) do
        [first | _] -> {:ok, first["page_id"] || first["id"]}
        _ -> :none
      end
    end
  end

  # ── normalize to one creative shape ───────────────────────────────────────────

  defp normalize_ad(ad) when is_map(ad) do
    img = dig1(ad, ["snapshot", "images", 0, "original_image_url"]) || ad["image_url"] || ad["thumbnail"]
    %{platform: "meta", image: img, text: ad["body"] || dig1(ad, ["snapshot", "body", "text"]) || "", link: ad["link_url"] || ad["url"]}
  end

  defp normalize_ad(_), do: nil

  defp normalize_social(p) when is_map(p) do
    %{platform: "instagram", image: p["display_url"] || p["thumbnail_url"], text: p["caption"] || "", link: p["permalink"] || p["url"]}
  end

  defp normalize_social(_), do: nil

  # ── http (authed GET, JSON) ───────────────────────────────────────────────────

  defp get(path, params) do
    :inets.start()
    :ssl.start()
    qs = params |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
    url = "#{@base}#{path}?#{qs}" |> String.to_charlist()
    headers = [{~c"x-api-key", String.to_charlist(key())}, {~c"accept", ~c"application/json"}]

    case :httpc.request(:get, {url, headers}, [timeout: 20_000, connect_timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp strip_handle(h), do: h |> to_string() |> String.split("/") |> Enum.reject(&(&1 == "")) |> List.last() |> to_string() |> String.trim_leading("@")

  # tolerant nested access — missing path → [] (so a shape change degrades, never crashes)
  defp dig(map, keys) do
    case get_in(map, keys) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp dig1(map, keys), do: get_in_safe(map, keys)

  defp get_in_safe(v, []), do: v
  defp get_in_safe(map, [k | rest]) when is_map(map), do: get_in_safe(Map.get(map, k), rest)
  defp get_in_safe(list, [i | rest]) when is_list(list) and is_integer(i), do: get_in_safe(Enum.at(list, i), rest)
  defp get_in_safe(_, _), do: nil
end
