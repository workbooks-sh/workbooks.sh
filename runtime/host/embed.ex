defmodule Workbooks.Embed do
  @moduledoc """
  Text → vector — the embedding provider slot (same pattern as Storage/Browse).
  Selected by `WB_EMBED`:

    - `hash` (default) — zero-dep, offline, DETERMINISTIC feature-hashing of
      character n-grams. A real LEXICAL-vector baseline (typo/substring tolerant),
      so the whole vector pipeline works out of the box with no key + no model.
      Not deeply semantic — that's the upgrade.
    - `openrouter` — true semantic vectors via an OpenAI-compatible /embeddings
      endpoint, reusing the existing LLM key. Per-query cost.
    - `local` — a small model resident in the BEAM (all-MiniLM / EmbeddingGemma
      via ortex/Bumblebee), serving every tenant from one load: the multi-tenant
      semantic default. Heavy dep → wired in a later step (honest stub for now).

  Embed at STORE time, not query time (see docs/VECTOR-QUERY.org).
  """
  @callback embed(texts :: [String.t()]) :: {:ok, [[float]]} | {:error, term}
  @callback dim() :: pos_integer()

  def adapter do
    case System.get_env("WB_EMBED", "hash") do
      "openrouter" -> Workbooks.Embed.OpenRouter
      "local" -> Workbooks.Embed.Local
      _ -> Workbooks.Embed.Hash
    end
  end

  @doc "Embed one or many texts → {:ok, [vector]} | {:error, _}."
  def embed(text) when is_binary(text) do
    case embed([text]), do: ({:ok, [v]} -> {:ok, v}; e -> e)
  end

  def embed(texts) when is_list(texts), do: adapter().embed(texts)

  @doc "The active adapter's vector dimension."
  def dim, do: adapter().dim()

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
    case System.get_env("OPENROUTER_API_KEY") do
      nil -> {:error, "OPENROUTER_API_KEY not set"}
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
