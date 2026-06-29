defmodule Nexus.Embed do
  @moduledoc """
  The **nexus's own embedding service** — a keyless, self-contained `embed(texts) -> [vector]` seam.

  Text embeddings power the semantic reranker (`Nexus.Browse.Search.Semantic`) without any external
  API key. The seam is **swappable**: a provider is any module with `embed(texts) -> [[float]]` and
  `dim/0`. The provider is selected (in order) by:

    1. the `:provider` option passed to `embed/2`, then
    2. `Nexus.Config`'s `embed` attr (`deploy embed="…"`) resolved to a module, then
    3. the built-in default below.

  ## Backends

    * `Nexus.Embed.Hashed` (**default, shipped, zero-dep**) — a deterministic hashed character-trigram
      bag-of-ngrams projected to a fixed-dim L2-normalized vector. NOT semantically deep, but it is a
      **live, correct, fully local** embedding: lexical/character overlap → cosine similarity, so the
      rerank PIPELINE is end-to-end real (and cheap enough for hundreds of concurrent agents on 1GB).

    * **THE MODEL-SWAP POINT** — to serve a real semantic model (bge-small / nomic-embed via a local
      llama.cpp GGUF lane, or Bumblebee if added), implement a module with `embed/1` + `dim/0` that
      calls it (route heavy batches through `Nexus.Constellation.Lane` like the LLM lanes) and set
      `deploy embed="bge-small"` (add the name→module mapping in `provider/1`). Nothing else in
      the search pipeline changes — `Semantic` only sees `embed(texts) -> [vector]`.
  """

  @callback embed([String.t()]) :: [[float]]
  @callback dim() :: pos_integer()

  @doc "Embed a batch of texts → a list of unit-length float vectors (one per input)."
  @spec embed([String.t()], keyword) :: [[float]]
  def embed(texts, opts \\ []) when is_list(texts) do
    provider(opts[:provider]).embed(texts)
  end

  @doc "Embed a single text → one vector."
  @spec embed_one(String.t(), keyword) :: [float]
  def embed_one(text, opts \\ []), do: embed([text], opts) |> List.first()

  @doc "Cosine similarity of two same-length vectors (vectors here are already L2-normalized → dot)."
  @spec cosine([float], [float]) :: float
  def cosine(a, b) when is_list(a) and is_list(b) do
    Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  end

  @doc "The active provider module (option → config → default)."
  def provider(nil) do
    case configured() do
      mod when is_atom(mod) and mod != nil -> mod
      _ -> Nexus.Embed.Hashed
    end
  end

  def provider(mod) when is_atom(mod), do: mod
  def provider("hashed"), do: Nexus.Embed.Hashed
  # MODEL-SWAP POINT — pure-Elixir static semantic embeddings (potion-style); falls back to Hashed
  # until a distilled table is configured. Add "bge-small" => Nexus.Embed.Bge here when the GGUF lane lands.
  def provider("model2vec"), do: Nexus.Embed.Model2Vec
  # Hosted semantic embeddings over the Cloudflare AI Gateway (default nomic-embed-text-v1.5, MRL-native).
  def provider("nomic"), do: Nexus.Embed.Gateway
  def provider("cf-bge"), do: Nexus.Embed.Gateway
  def provider("gateway"), do: Nexus.Embed.Gateway
  def provider(_), do: Nexus.Embed.Hashed

  defp configured do
    if Code.ensure_loaded?(Nexus.Config) and function_exported?(Nexus.Config, :embed, 0) do
      case Nexus.Config.embed() do
        name when is_binary(name) -> provider(name)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end
end

defmodule Nexus.Embed.Hashed do
  @moduledoc """
  Deterministic, dependency-free embedding: bag of character trigrams (+ word unigrams) hashed into a
  fixed-dim vector with signed buckets (the hashing-trick), then L2-normalized. Cosine similarity then
  measures lexical/character overlap between query and candidate — a real, swappable embedding that
  makes the rerank pipeline live end-to-end. Swap for a true semantic model at `Nexus.Embed`'s
  documented model-swap point.
  """
  @behaviour Nexus.Embed

  @dim 256

  @impl true
  def dim, do: @dim

  @impl true
  def embed(texts), do: Enum.map(texts, &vec/1)

  defp vec(text) do
    text = text |> to_string() |> String.downcase()
    features = trigrams(text) ++ words(text)

    acc =
      Enum.reduce(features, %{}, fn f, acc ->
        h = :erlang.phash2(f, @dim * 2)
        bucket = rem(h, @dim)
        sign = if rem(div(h, @dim), 2) == 0, do: 1.0, else: -1.0
        Map.update(acc, bucket, sign, &(&1 + sign))
      end)

    raw = for i <- 0..(@dim - 1), do: Map.get(acc, i, 0.0)
    norm = :math.sqrt(Enum.reduce(raw, 0.0, fn x, a -> a + x * x end))
    if norm == 0.0, do: raw, else: Enum.map(raw, &(&1 / norm))
  end

  defp trigrams(text) do
    g = " " <> text <> " "
    case String.graphemes(g) do
      gs when length(gs) >= 3 ->
        gs |> Enum.chunk_every(3, 1, :discard) |> Enum.map(&Enum.join/1)
      _ -> []
    end
  end

  defp words(text), do: text |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
end
