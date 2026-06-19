defmodule Nexus.Browse.Search.Semantic do
  @moduledoc """
  **Local semantic reranker** for the fused metasearch results — keyless, self-contained.

  Given the query and the merged candidate list (each `%{title, url, snippet, score, ...}` from
  `Nexus.Browse.Search.Rank`), it embeds the query and each candidate's `title + snippet` via the
  `Nexus.Embed` seam, computes cosine similarity, and **blends** the cross-engine RRF score with the
  semantic score so neither dominates:

      blended = (1 - α) · rrf_norm + α · cosine

  where `rrf_norm` is the RRF score min-max normalized across the candidate set and `α` (`:alpha`,
  default 0.5) tunes the blend. Pure given an embedding backend; the embedding model is swappable at
  `Nexus.Embed`'s model-swap point without touching this module.
  """

  alias Nexus.Embed

  @default_alpha 0.5

  @doc """
  Rerank `candidates` against `query`. Each candidate gets `:semantic` (cosine) and `:score`
  (blended) added; the list is returned sorted by blended score descending.

  Options: `:alpha` (blend weight, 0..1), `:provider` (embedding provider override).
  """
  @spec rerank(String.t(), [map], keyword) :: [map]
  def rerank(query, candidates, opts \\ [])
  def rerank(_query, [], _opts), do: []

  def rerank(query, candidates, opts) do
    alpha = opts[:alpha] || @default_alpha
    qvec = Embed.embed_one(query, opts)

    texts = Enum.map(candidates, &cand_text/1)
    vecs = Embed.embed(texts, opts)

    rrf_scores = Enum.map(candidates, &(&1[:score] || 0.0))
    {lo, hi} = Enum.min_max(rrf_scores, fn -> {0.0, 1.0} end)
    span = if hi - lo == 0.0, do: 1.0, else: hi - lo

    candidates
    |> Enum.zip(vecs)
    |> Enum.map(fn {c, v} ->
      cos = Embed.cosine(qvec, v)
      rrf_norm = ((c[:score] || 0.0) - lo) / span
      blended = (1 - alpha) * rrf_norm + alpha * cos

      c
      |> Map.put(:semantic, Float.round(cos, 4))
      |> Map.put(:rrf, c[:score] || 0.0)
      |> Map.put(:score, Float.round(blended, 4))
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp cand_text(c) do
    [c[:title], c[:snippet]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")
  end
end
