defmodule Workbooks.Embed do
  @moduledoc """
  The embedding provider registry — OPEN + modality-aware. You connect ANY
  embedder and the system routes by modality (text / image / video / …). Built-in
  text adapters, plus a generic `Http` connector so you can plug an external model
  on Modal / Replicate / Fly GPU / a HF Inference Endpoint / OpenRouter — wherever.

  Two shapes, operator's choice:
    * ONE unified model for everything — `WB_EMBED_MULTIMODAL=http:<url>` (e.g.
      CLIP for text+image, or VLM2Vec for text+image+video). Text and image land
      in the SAME space, so cross-modal search (text query → image hits) works.
    * SEPARATE models per modality — `WB_EMBED` for text (default), plus
      `WB_EMBED_IMAGE` / `WB_EMBED_VIDEO` = `http:<url>`. (Different providers =
      different spaces: text-finds-text, image-finds-image, but NOT cross — for
      cross-modal use one unified provider.)

  Adapter specs: `local` (Model2Vec, text) · `hash` (lexical text) · `openrouter`
  (OpenAI-compatible text) · `http:<url>` (any endpoint, any modality). Embed at
  STORE time, not query time (docs/VECTOR-QUERY.org, MULTIMODAL-EMBED-SPIKE.org).
  """
  @callback embed(inputs :: [term]) :: {:ok, [[float]]} | {:error, term}
  @callback dim() :: pos_integer()

  @doc "The text adapter module (for dim + the boot log + the Vector store)."
  def adapter, do: text_adapter()

  defp text_adapter do
    case System.get_env("WB_EMBED", "hash") do
      "openrouter" -> Workbooks.Embed.OpenRouter
      "local" -> Workbooks.Embed.Local
      _ -> Workbooks.Embed.Hash
    end
  end

  @doc "Embed one or many inputs for a modality (default :text) → {:ok, [vector]} | {:error, _}."
  def embed(input, modality \\ :text)

  def embed(input, modality) when is_binary(input) do
    case embed([input], modality), do: ({:ok, [v]} -> {:ok, v}; e -> e)
  end

  def embed(inputs, modality) when is_list(inputs) do
    case provider(modality) do
      {:http, url} -> Workbooks.Embed.Http.embed(url, inputs, modality)
      {:clip} -> clip_embed(inputs, modality)
      nil -> {:error, "no embedder configured for #{modality} — set WB_EMBED_#{up(modality)}=http:<url> (or WB_EMBED=clip / WB_EMBED_MULTIMODAL)"}
      mod when modality == :text -> apply(mod, :embed, [inputs])
      _ -> {:error, "#{modality} needs an external embedder — set WB_EMBED_#{up(modality)}=http:<url> (or WB_EMBED=clip for in-BEAM image+text)"}
    end
  end

  # In-BEAM CLIP (ONNX via Ortex) — present only in a WB_CLIP=1 build, so we reach
  # it dynamically; the lean build returns an honest, actionable error.
  defp clip_embed(inputs, modality) do
    if Code.ensure_loaded?(Workbooks.Embed.OrtexClip) do
      apply(Workbooks.Embed.OrtexClip, :embed, [inputs, modality])
    else
      {:error, "in-BEAM CLIP not built — rebuild with WB_CLIP=1 (or point WB_EMBED_IMAGE=http:<url> at an external embedder)"}
    end
  end

  # The provider for a modality: a single multimodal endpoint covers all
  # modalities (one space); else per-modality config; text falls back to built-in.
  defp provider(modality) do
    cond do
      url = endpoint("WB_EMBED_MULTIMODAL") -> {:http, url}
      modality == :text -> spec(System.get_env("WB_EMBED", "hash"))
      m = System.get_env("WB_EMBED_#{up(modality)}") -> spec(m)
      System.get_env("WB_EMBED") == "clip" -> {:clip}
      true -> nil
    end
  end

  defp endpoint(var), do: (case System.get_env(var), do: ("http:" <> u -> u; _ -> nil))
  defp up(m), do: m |> to_string() |> String.upcase()

  defp spec(nil), do: nil
  defp spec("local"), do: Workbooks.Embed.Local
  defp spec("openrouter"), do: Workbooks.Embed.OpenRouter
  defp spec("clip"), do: {:clip}
  defp spec("http:" <> url), do: {:http, url}
  defp spec(_), do: Workbooks.Embed.Hash

  @doc """
  Embed a TEXT query in the SPACE of `modality`'s embedder — for cross-modal
  search (e.g. a text query against CLIP image vectors: CLIP is one space, so the
  query goes through the IMAGE provider in text mode). Falls back to the text
  embedder if that modality has no distinct provider.
  """
  def embed_query_for(modality, text) do
    result =
      case provider(modality) do
        {:http, url} -> Workbooks.Embed.Http.embed(url, [text], :text)
        _ -> embed([text], :text)
      end

    case result, do: ({:ok, [v]} -> {:ok, v}; e -> e)
  end

  @doc "The active text adapter's vector dimension."
  def dim, do: text_adapter().dim()

  @doc "Cosine similarity of two equal-length vectors."
  def cosine(a, b) do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, sa, sb} -> {d + x * y, sa + x * x, sb + y * y} end)

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (:math.sqrt(na) * :math.sqrt(nb))
  end
end

defmodule Workbooks.Embed.Hash do
  @moduledoc "Zero-dep lexical vectors via the hashing trick on char 3-grams + word tokens."
  @behaviour Workbooks.Embed
  @dim 256

  @impl true
  def dim, do: @dim

  @impl true
  def embed(texts), do: {:ok, Enum.map(texts, &vector/1)}

  defp vector(text) do
    features = tokens(text)
    acc = :array.new(@dim, default: 0.0)

    acc =
      Enum.reduce(features, acc, fn f, a ->
        i = rem(:erlang.phash2(f), @dim)
        sign = if rem(:erlang.phash2({f, :s}), 2) == 0, do: 1.0, else: -1.0
        :array.set(i, :array.get(i, a) + sign, a)
      end)

    l2_normalize(:array.to_list(acc))
  end

  # char 3-grams (fuzzy/substring) + whitespace word tokens (lexical).
  defp tokens(text) do
    t = text |> String.downcase()
    words = String.split(t, ~r/\s+/, trim: true)
    grams = t |> String.replace(~r/\s+/, " ") |> ngrams(3)
    words ++ grams
  end

  defp ngrams(s, n) do
    cs = String.graphemes(s)
    if length(cs) < n, do: [s], else: cs |> Enum.chunk_every(n, 1, :discard) |> Enum.map(&Enum.join/1)
  end

  defp l2_normalize(v) do
    norm = v |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
    if norm == 0.0, do: v, else: Enum.map(v, &(&1 / norm))
  end
end

defmodule Workbooks.Embed.OpenRouter do
  @moduledoc "Semantic vectors via an OpenAI-compatible /embeddings endpoint, reusing the LLM key."
  @behaviour Workbooks.Embed
  @endpoint ~c"https://openrouter.ai/api/v1/embeddings"
  @default_model "openai/text-embedding-3-small"

  @impl true
  def dim, do: String.to_integer(System.get_env("WB_EMBED_DIM", "1536"))

  @impl true
  def embed(texts) do
    case Workbooks.Secrets.get("OPENROUTER_API_KEY") do
      k when k in [nil, ""] -> {:error, "OPENROUTER_API_KEY not set"}
      key -> do_embed(texts, key)
    end
  end

  defp do_embed(texts, key) do
    body = Jason.encode!(%{model: System.get_env("WB_EMBED_MODEL", @default_model), input: texts})

    headers = [
      {~c"authorization", to_charlist("Bearer " <> key)},
      {~c"content-type", ~c"application/json"}
    ]

    :inets.start()
    :ssl.start()

    case :httpc.request(:post, {@endpoint, headers, ~c"application/json", body}, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, Jason.decode!(resp)["data"] |> Enum.map(& &1["embedding"])}

      {:ok, {{_, c, _}, _, resp}} -> {:error, "HTTP #{c}: #{String.slice(resp, 0, 200)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end
end

defmodule Workbooks.Embed.Http do
  @moduledoc """
  The OPEN connection — any external embedder, any modality. POSTs
  `{"inputs": [...], "modality": "text"|"image"|...}` to a configured endpoint and
  reads vectors back (accepts `vectors` / `embeddings` / OpenAI `data[].embedding`).
  Point a `WB_EMBED_*` var at it (`http:<url>`) and that's the model — Modal,
  Replicate, Fly GPU, a HF Inference Endpoint, an OpenAI-compatible service, your
  own sidecar. Auth via `WB_EMBED_KEY` (Bearer). The provider sets its modalities
  by WHICH var points here (e.g. WB_EMBED_IMAGE, or WB_EMBED_MULTIMODAL for all).
  """
  def embed(url, inputs, modality) do
    body = Jason.encode!(%{inputs: inputs, modality: to_string(modality)})
    headers = [{~c"content-type", ~c"application/json"} | auth()]
    :inets.start()
    :ssl.start()

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", body}, [timeout: 120_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        d = Jason.decode!(resp)
        {:ok, d["vectors"] || d["embeddings"] || (d["data"] && Enum.map(d["data"], & &1["embedding"]))}

      {:ok, {{_, c, _}, _, r}} -> {:error, "HTTP #{c}: #{String.slice(r, 0, 200)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp auth do
    case System.get_env("WB_EMBED_KEY") do
      nil -> []
      k -> [{~c"authorization", String.to_charlist("Bearer " <> k)}]
    end
  end
end

defmodule Workbooks.Embed.Local do
  @moduledoc """
  The real semantic embedder — Model2Vec/potion STATIC embeddings, PURE ELIXIR
  (no native NIF, no model runtime, no wasm). One small matrix (~30 MB) resident
  in :persistent_term serves every tenant. Downloaded once to the storage volume,
  then it's just tokenize + matrix lookup + mean-pool. Smallest-to-ship + multi-
  tenant + satisfies "WASM or Elixir". See `Workbooks.Embed.Model2Vec`.
  """
  @behaviour Workbooks.Embed
  @impl true
  def dim, do: String.to_integer(System.get_env("WB_EMBED_DIM", "256"))

  @impl true
  def embed(texts) do
    model = Workbooks.Embed.Model2Vec.get()
    {:ok, Workbooks.Embed.Model2Vec.embed(texts, model)}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
