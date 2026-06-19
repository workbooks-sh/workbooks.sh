defmodule Nexus.Browse.Search.Brave do
  @moduledoc """
  The keyed **cloud** `:search` provider — the Brave Search API (own index, clean JSON, reliable from
  any IP incl. Fly datacenter ranges). The recommended cloud default: select it with
  `<work-deploy search="brave">`. See `docs/SEARCH-ARCHITECTURE.md` §4.

  `GET https://api.search.brave.com/res/v1/web/search?q=…` with an `X-Subscription-Token` header. The
  key is a secret, so it stays in the env (`BRAVE_API_KEY`) — the same carve-out `Nexus.Config`
  documents for `OPENROUTER_API_KEY`. Maps Brave's `web.results[]` (`title`/`url`/`description`) to
  the shared `%{title, url, snippet}` shape.

  Stub-testable: pass `opts[:fetch]` (a `url, headers -> {:ok, json} | {:error, _}` fun) to inject a
  response without touching the network; production calls go through `Nexus.Dock.get/2`.
  """
  @behaviour Nexus.Browse

  @endpoint "https://api.search.brave.com/res/v1/web/search"
  @top_n 10

  @impl true
  def capabilities, do: [:search]

  @impl true
  def search(query, opts \\ []) do
    query = String.trim(query || "")
    key = api_key()

    cond do
      query == "" ->
        {:error, :empty_query}

      key in [nil, ""] ->
        {:error, :missing_brave_api_key}

      true ->
        limit = opts[:limit] || @top_n
        url = "#{@endpoint}?#{URI.encode_query(q: query, count: limit)}"
        headers = [{"X-Subscription-Token", key}, {"Accept", "application/json"}]

        with {:ok, body} <- do_get(opts, url, headers),
             {:ok, json} <- decode(body) do
          {:ok, json |> parse() |> Enum.take(limit)}
        end
    end
  end

  @doc false
  def parse(%{"web" => %{"results" => results}}) when is_list(results) do
    Enum.map(results, fn r ->
      %{
        title: r["title"] || "",
        url: r["url"] || "",
        snippet: strip_tags(r["description"] || "")
      }
    end)
  end

  def parse(_), do: []

  defp do_get(opts, url, headers) do
    case opts[:fetch] do
      fun when is_function(fun, 2) -> fun.(url, headers)
      _ -> Nexus.Dock.get(url, headers)
    end
  end

  defp decode(json) when is_map(json), do: {:ok, json}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      _ -> {:error, :bad_json}
    end
  end

  defp api_key, do: System.get_env("BRAVE_API_KEY")

  # Brave wraps query-term matches in <strong>; the result list wants plain text.
  defp strip_tags(s), do: s |> String.replace(~r/<[^>]+>/, "") |> String.trim()
end
