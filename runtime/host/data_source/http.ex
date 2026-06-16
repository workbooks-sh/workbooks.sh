defmodule Workbooks.DataSource.Http do
  @moduledoc """
  Generic JSON-API data source (wb-39j.3) — makes ANY JSON HTTP endpoint a
  federation data source. A plugin manifest declares a `<work-toolkit>` with a
  data-source slot, e.g.:

      <work-toolkit
        slot="data-source"
        entities="<entity>"
        impl="Workbooks.DataSource.Http"
        url="https://api.example.com/items"
        rows-path="data.items"      <!-- dotted path to the array in the response (optional) -->
        env-keys="EXAMPLE_API_KEY">  <!-- bearer credential, via Plugin.Auth (optional) -->

  `SELECT … FROM <entity>` → GET the URL (Bearer auth resolved through
  Plugin.Auth — the plugin never holds the raw key) → extract the row array. This
  is the pattern Linear/Asana specialize (their own query/3 translating the SQL
  query → their GraphQL); this generic one covers plain REST/JSON sources with zero
  code.
  """
  @behaviour Workbooks.DataSource

  @impl true
  def query(_entity, %{config: cfg}, opts) do
    case cfg["url"] do
      url when is_binary(url) and url != "" ->
        get = opts[:http] || (&default_get/2)

        case get.(url, auth_headers(cfg, opts)) do
          {:ok, body} -> {:ok, extract_rows(body, cfg["rows_path"])}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :no_url}
    end
  end

  # Bearer header from the first #+ENV_KEYS credential, resolved via Plugin.Auth.
  defp auth_headers(cfg, opts) do
    case cfg["env_keys"] do
      [key | _] ->
        case Workbooks.Plugin.Auth.fetch(key, opts) do
          token when is_binary(token) -> [{~c"authorization", String.to_charlist("Bearer " <> token)}]
          _ -> []
        end

      _ ->
        []
    end
  end

  # Pull the row array out of the JSON via a dotted #+ROWS_PATH (nil → the body IS
  # the array). Non-map elements are dropped; rows are headline-shaped maps.
  defp extract_rows(body, rows_path) do
    json = if is_binary(body), do: Jason.decode!(body), else: body

    json
    |> dig(rows_path)
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp dig(json, nil), do: json
  defp dig(json, ""), do: json

  defp dig(json, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(json, fn key, acc -> if is_map(acc), do: Map.get(acc, key), else: nil end)
  end

  # Host egress (the plugin never opens a socket itself).
  defp default_get(url, headers) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:timeout, 10_000}], body_format: :binary) do
      {:ok, {{_, status, _}, _h, body}} when status in 200..299 -> {:ok, body}
      {:ok, {{_, status, _}, _h, _}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
