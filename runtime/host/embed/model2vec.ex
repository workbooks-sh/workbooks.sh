defmodule Workbooks.Embed.Model2Vec do
  @moduledoc """
  Static (Model2Vec / "potion") embeddings — PURE ELIXIR, no model runtime, no
  native NIF. A static embedding is just: tokenize → look up each token's vector
  in a precomputed matrix → mean-pool → normalize. No transformer forward pass, so
  the whole "model" is a vocab + a matrix (~8–30 MB), and inference is arithmetic.

  This is the smallest-to-ship, multi-tenant local embedder (one matrix resident,
  serves every tenant), satisfying "WASM or Elixir, no native NIF" via the Elixir
  path — nothing to compile, nothing to download at runtime but the matrix itself.
  Chosen over ORT-Web because it skips the runtime entirely (~3–5× smaller total).
  See docs/VECTOR-QUERY.org step 6.

  Loaded once into :persistent_term. `model` is %{vocab, unk, matrix, dim, normalize}.
  """

  # ── inference ─────────────────────────────────────────────────────────────────
  @doc "Embed texts with a loaded model → [vector]."
  def embed(texts, model), do: Enum.map(texts, &embed_one(&1, model))

  defp embed_one(text, %{vocab: vocab, unk: unk, matrix: matrix, dim: dim} = model) do
    vecs =
      text
      |> tokenize(vocab, unk)
      |> Enum.map(&Map.get(matrix, &1, List.duplicate(0.0, dim)))

    pooled = mean_pool(vecs, dim)
    if Map.get(model, :normalize, true), do: l2(pooled), else: pooled
  end

  # ── WordPiece tokenizer (pure Elixir — matches BERT-style models) ────────────
  defp tokenize(text, vocab, unk) do
    text
    |> String.downcase()
    |> pre_tokens()
    |> Enum.flat_map(&wordpiece(&1, vocab, unk))
  end

  # Split into word + punctuation tokens (BERT basic tokenizer, Unicode-aware).
  defp pre_tokens(text), do: Regex.scan(~r/\w+|[^\w\s]/u, text) |> Enum.map(&hd/1)

  defp wordpiece(word, vocab, unk), do: wp(String.graphemes(word), vocab, unk, true, [])

  defp wp([], _vocab, _unk, _first, acc), do: Enum.reverse(acc)

  defp wp(graphemes, vocab, unk, first, acc) do
    case longest_prefix(graphemes, vocab, first) do
      {id, rest} -> wp(rest, vocab, unk, false, [id | acc])
      # an unmatchable piece ⇒ this word is [UNK] (BERT WordPiece behavior); prior
      # words' tokens in `acc` are kept.
      :none -> Enum.reverse([unk | acc])
    end
  end

  defp longest_prefix(graphemes, vocab, first) do
    n = length(graphemes)

    Enum.find_value(n..1//-1, fn k ->
      {prefix, rest} = Enum.split(graphemes, k)
      tok = if(first, do: "", else: "##") <> Enum.join(prefix)
      case Map.get(vocab, tok), do: (nil -> nil; id -> {id, rest})
    end)
  end

  # ── vector math ───────────────────────────────────────────────────────────────
  defp mean_pool([], dim), do: List.duplicate(0.0, dim)

  defp mean_pool(vecs, _dim) do
    n = length(vecs)
    vecs |> Enum.zip_with(&Enum.sum/1) |> Enum.map(&(&1 / n))
  end

  defp l2(v) do
    norm = v |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
    if norm == 0.0, do: v, else: Enum.map(v, &(&1 / norm))
  end
end
