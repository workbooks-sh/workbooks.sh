defmodule Workbooks.Models do
  @moduledoc """
  OpenRouter model discovery (wb-d2nx.5) — so Waldo can find a model for a task
  (image, embedding, vision, cheap chat) and switch its OWN model. Reads the
  public OpenRouter /models catalog; filters by a free-text query against the id,
  name, and modality.
  """
  @endpoint ~c"https://openrouter.ai/api/v1/models"

  @doc """
  List models matching `query` (substring over id/name/modality; "" = all).
  Returns a compact text table (id · context · modality · prompt-price).
  """
  def list(query \\ "") do
    q = query |> to_string() |> String.downcase() |> String.trim()

    case fetch() do
      {:ok, models} ->
        rows =
          models
          |> Enum.filter(&match_query?(&1, q))
          |> Enum.sort_by(& &1["id"])
          |> Enum.take(60)

        if rows == [] do
          "no models match #{inspect(query)}"
        else
          header = "MODEL\tCONTEXT\tMODALITY\t$/Mtok-in"
          header <> "\n" <> Enum.map_join(rows, "\n", &row/1)
        end

      {:error, reason} ->
        "model list failed: #{inspect(reason)}"
    end
  end

  defp match_query?(_m, ""), do: true

  defp match_query?(m, q) do
    hay =
      [m["id"], m["name"], modality(m)]
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    String.contains?(hay, q)
  end

  defp row(m) do
    ctx = m["context_length"] || get_in(m, ["top_provider", "context_length"]) || 0
    price = get_in(m, ["pricing", "prompt"])
    per_m = if is_binary(price), do: format_price(price), else: "?"
    "#{m["id"]}\t#{ctx}\t#{modality(m)}\t#{per_m}"
  end

  defp modality(m), do: get_in(m, ["architecture", "modality"]) || get_in(m, ["architecture", "input_modalities"]) || "text"

  # OpenRouter prices are per-token strings; show $ per 1M tokens.
  defp format_price(p) do
    case Float.parse(p) do
      {f, _} -> "$" <> :erlang.float_to_binary(f * 1_000_000, decimals: 2)
      :error -> "?"
    end
  end

  defp fetch do
    :inets.start()
    :ssl.start()
    key = Workbooks.Secrets.get("OPENROUTER_API_KEY", "")
    headers = [{~c"authorization", ~c"Bearer #{key}"}]

    case :httpc.request(:get, {@endpoint, headers}, [timeout: 20_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
          _ -> {:error, :bad_body}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
