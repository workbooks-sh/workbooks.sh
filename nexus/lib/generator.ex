defmodule Nexus.Generator do
  @moduledoc """
  Run a Cloudflare generator model — text → image / video / audio — and store the result as an asset.

  This is the EXECUTION behind the generator toolkits (image-generation / video-generation / speech):
  the brain calls a `bash` command (`image`/`video`/`speak`), which lands here, which POSTs to the
  Cloudflare AI run endpoint, decodes the asset (raw binary OR base64-in-JSON, both shapes occur), and
  persists it via `Nexus.Assets`, returning a browser-reachable URL.

  Generic mechanism over the open CF API — credentials come from `Nexus.Secrets` (the same
  CLOUDFLARE_* / CF_AIG_* keys the text inference path uses), defaults are public CF models, and the
  caller may override the model. No Workbooks business baked in.
  """

  # Sensible public defaults per modality — overridable with `--model <id>` at the call site. These are
  # routable CF model ids; the roster (catalog) can drive a smarter pick, but a default makes it work now.
  @defaults %{
    "image" => "@cf/black-forest-labs/flux-1-schnell",
    "audio" => "@cf/myshell-ai/melotts"
    # video: no stable default Workers-AI text-to-video — caller must pass --model (e.g. a gateway video model).
  }

  @ct %{"image" => "image/png", "video" => "video/mp4", "audio" => "audio/mpeg"}

  @doc """
  Generate an asset. `modality` ∈ "image" | "video" | "audio". Returns `{:ok, asset_map}` (with `:model`
  and the `Nexus.Assets` fields incl. `:url`) or `{:error, reason}`.
  """
  def run(modality, prompt, tenant, opts \\ []) do
    model = opts[:model] || Map.get(@defaults, modality)

    cond do
      is_nil(model) ->
        {:error,
         "no default #{modality} model — pass --model <id> (e.g. a gateway text-to-#{modality} model)"}

      String.trim(to_string(prompt)) == "" ->
        {:error, "empty prompt"}

      true ->
        with {:ok, bytes, ct} <- invoke(model, modality, prompt),
             {:ok, asset} <- Nexus.Assets.put(tenant, bytes, ct) do
          {:ok, Map.put(asset, :model, model)}
        end
    end
  end

  # POST to the Cloudflare account-scoped AI run endpoint. Workers-AI generators return either the raw
  # binary (content-type image/*, audio/*, video/*) or a JSON envelope `{"result": {"image"|"audio"|
  # "video": "<base64>"}}` — handle both.
  defp invoke(model, modality, prompt) do
    account = Nexus.Secrets.get("CLOUDFLARE_ACCOUNT_ID")
    token = Nexus.Secrets.get("CLOUDFLARE_API_TOKEN") || Nexus.Secrets.get("CF_AIG_TOKEN")

    cond do
      account in [nil, ""] or token in [nil, ""] ->
        {:error, "Cloudflare not configured (need CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN)"}

      true ->
        :inets.start()
        :ssl.start()
        url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run/#{model}"
        body = Jason.encode!(%{prompt: to_string(prompt)})
        headers = [{~c"authorization", ~c"Bearer #{token}"}]
        req = {to_charlist(url), headers, ~c"application/json", body}

        case :httpc.request(:post, req, [timeout: 120_000, ssl: [verify: :verify_none]], body_format: :binary) do
          {:ok, {{_, 200, _}, resp_headers, resp}} -> decode_asset(modality, resp_headers, resp)
          {:ok, {{_, code, _}, _h, resp}} -> {:error, "cloudflare #{code}: #{String.slice(resp, 0, 240)}"}
          {:error, e} -> {:error, "request failed: #{inspect(e)}"}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    _, e -> {:error, inspect(e)}
  end

  defp decode_asset(modality, headers, resp) do
    ct = header(headers, ~c"content-type")
    json? = (is_binary(ct) and String.contains?(ct, "application/json")) or String.starts_with?(resp, "{")

    cond do
      json? ->
        case Jason.decode(resp) do
          {:ok, %{"result" => r}} when is_map(r) -> from_json_result(modality, r)
          {:ok, %{"errors" => errs}} -> {:error, "cloudflare: #{inspect(errs) |> String.slice(0, 240)}"}
          _ -> {:error, "unparseable generator response"}
        end

      true ->
        {:ok, resp, (is_binary(ct) && ct) || @ct[modality]}
    end
  end

  defp from_json_result(modality, r) do
    b64 = r["image"] || r["audio"] || r["video"] || r["data"]

    case is_binary(b64) && Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin, @ct[modality]}
      _ -> {:error, "no asset in result (keys: #{r |> Map.keys() |> Enum.join(", ")})"}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if to_string(k) |> String.downcase() == to_string(name) |> String.downcase(), do: to_string(v)
    end)
  end
end
