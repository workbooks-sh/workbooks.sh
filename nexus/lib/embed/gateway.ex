defmodule Nexus.Embed.Gateway do
  @moduledoc """
  Hosted semantic-embedding provider over the **Cloudflare AI Gateway** (OpenAI-compatible
  `/embeddings`), defaulting to **nomic-embed-text-v1.5** — a Matryoshka-native model, so the
  Skill-KB two-tier recall's `embed64` slice (first-64-dims, renormalized) is a *genuine* MRL
  embedding, not a mechanical truncation.

  Mirrors `Nexus.Llm`'s endpoint/secret seam exactly — no new transport, no new key convention:

    * base URL: `embed_base_url` config → else the AI Gateway base in `CF_AIG_URL` (secret) with
      `/embeddings` appended → else the CF native `…/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1/embeddings`.
    * key: `CF_AIG_TOKEN` (gateway) or `CLOUDFLARE_API_TOKEN` (native), read via `Nexus.Secrets`
      (never `System.get_env`).
    * model: `embed_model_id` config, default `nomic-embed-text-v1.5`; `embed_dim` config, default 768.

  Transport is built-in `:httpc` + `Jason` (same as `Nexus.Llm`). If no endpoint/key is configured it
  **falls back to `Nexus.Embed.Hashed`**, so `deploy embed="nomic"` never breaks ingest — quality
  simply tracks whether the gateway is wired. Returned vectors are L2-normalized for cosine.
  """
  @behaviour Nexus.Embed

  @default_model "nomic-embed-text-v1.5"
  # Cloudflare Workers AI embedding model (via the AI Gateway compat endpoint) — 768-dim, matches @default_dim.
  @cf_model "workers-ai/@cf/baai/bge-base-en-v1.5"
  @default_dim 768
  @timeout 20_000

  @impl true
  def dim, do: cfg(:embed_dim, @default_dim)

  @impl true
  def embed(texts) do
    case endpoint() do
      {:ok, url, key, model} ->
        case request(url, key, build_body(model, texts)) do
          {:ok, decoded} -> parse_embeddings(decoded, length(texts))
          {:error, _} -> fallback(texts)
        end

      :unconfigured ->
        fallback(texts)
    end
  end

  # ── pure, testable pieces ───────────────────────────────────────────────────

  @doc "OpenAI-compatible embeddings request body."
  @spec build_body(String.t(), [String.t()]) :: map
  def build_body(model, texts), do: %{model: model, input: texts}

  @doc "Parse an OpenAI-compatible embeddings response → a list of L2-normalized vectors (order-stable)."
  @spec parse_embeddings(map, non_neg_integer) :: [[float]]
  def parse_embeddings(%{"data" => data}, _n) when is_list(data) do
    data
    |> Enum.sort_by(&(&1["index"] || 0))
    |> Enum.map(fn d -> l2(d["embedding"] || []) end)
  end

  def parse_embeddings(_, n), do: List.duplicate([], n)

  # ── endpoint resolution (mirrors Nexus.Llm) ─────────────────────────────────

  defp endpoint do
    model = cfg(:embed_model_id, @default_model)

    cond do
      (base = cfg(:embed_base_url, nil)) not in [nil, ""] ->
        {:ok, join(base, "/embeddings"), secret("CF_AIG_TOKEN") || secret("OPENROUTER_API_KEY"), model}

      (aig = secret("CF_AIG_URL")) not in [nil, ""] ->
        # The AI Gateway compat embeddings endpoint is `.../compat/embeddings` — derive it from the chat
        # URL (CF_AIG_URL is the `.../compat/chat/completions` form); appending "/embeddings" is wrong.
        {:ok, compat_embeddings_url(aig), secret("CF_AIG_TOKEN"), cfg(:embed_model_id, @cf_model)}

      (account = secret("CLOUDFLARE_ACCOUNT_ID")) not in [nil, ""] ->
        url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/v1/embeddings"
        {:ok, url, secret("CLOUDFLARE_API_TOKEN"), cfg(:embed_model_id, @cf_model)}

      true ->
        :unconfigured
    end
  end

  defp fallback(texts), do: Nexus.Embed.Hashed.embed(texts)

  # ── transport (:httpc + Jason, same as Nexus.Llm) ───────────────────────────

  defp request(_url, key, _body) when key in [nil, ""], do: {:error, :no_api_key}

  defp request(url, key, body) do
    # HTTPS needs ssl started in this process tree (mirrors Nexus.Llm) — without it :httpc raises and we'd
    # silently fall back to the hashed embedder. Idempotent.
    :ssl.start()
    :inets.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}]
    req = {to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    try do
      case :httpc.request(:post, req, [timeout: @timeout], body_format: :binary) do
        {:ok, {{_, 200, _}, _h, resp}} ->
          case Jason.decode(resp) do
            {:ok, decoded} -> {:ok, decoded}
            _ -> {:error, :bad_json}
          end

        {:ok, {{_, status, _}, _h, resp}} ->
          {:error, {:http, status, String.slice(to_string(resp), 0, 200)}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # ── utils ───────────────────────────────────────────────────────────────────

  defp secret(name) do
    if Code.ensure_loaded?(Nexus.Secrets), do: Nexus.Secrets.get(name)
  rescue
    _ -> nil
  end

  defp cfg(key, default) do
    if Code.ensure_loaded?(Nexus.Config) and function_exported?(Nexus.Config, :get, 1) do
      Nexus.Config.get(key) || default
    else
      default
    end
  rescue
    _ -> default
  end

  defp join(base, path), do: String.trim_trailing(base, "/") <> path

  # The AI Gateway OpenAI-compat embeddings URL, derived from the chat-completions URL (CF_AIG_URL).
  defp compat_embeddings_url(url) do
    cond do
      String.contains?(url, "/chat/completions") -> String.replace(url, "/chat/completions", "/embeddings")
      String.ends_with?(url, "/embeddings") -> url
      true -> join(url, "/embeddings")
    end
  end

  defp l2(vec) do
    n = vec |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
    if n == 0.0, do: vec, else: Enum.map(vec, &(&1 / n))
  end
end
