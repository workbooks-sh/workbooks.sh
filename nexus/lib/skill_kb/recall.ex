defmodule Nexus.SkillKB.Recall do
  @moduledoc """
  S4 retrieval: brute-force cosine `top_k` over inline vectors, two-tier (MRL pre-filter → full rerank).

  `Nexus.Store` rows are term blobs (not SQL-queryable), so retrieval loads all rows and scores in
  Elixir — the intended no-ANN design at thousands-of-rows scale. `top_k/3` first ranks every row on
  the cheap `embed64` slice, keeps the best `:prefilter` (~200), then re-scores those on the full
  `embed`. Blocked rows (those without vectors) fall out naturally. Pure over the row list, so it is
  trivially testable; `search/4` is the Store-backed convenience.
  """

  alias Nexus.{Embed, Store, SkillKB.Index}

  # The cheap-tier `embed64` (MRL slice) prefilter is only valid for Matryoshka-trained models. For any
  # corpus at or below this size we skip it and rerank ALL rows on the full vector — correct for any
  # embedder (e.g. bge-base, which is NOT MRL, so its first-64-dims don't preserve similarity). Above it,
  # the prefilter kicks in for scale (and a real MRL model should back `embed64`).
  @prefilter 5000

  @doc """
  Rank `rows` against a `{full, small}` query embedding. Returns the top `k` rows, each with a
  `:score` (full-vector cosine) added, highest first. `opts[:prefilter]` caps the cheap-tier shortlist.
  """
  @spec top_k([map], {[float], [float]}, pos_integer, keyword) :: [map]
  def top_k(rows, {qfull, qsmall}, k, opts \\ []) do
    prefilter = opts[:prefilter] || @prefilter

    # Small corpus → rerank every row on the FULL vector (no lossy embed64 prefilter). Large corpus →
    # use the embed64 cheap tier to shortlist before the full rerank.
    candidates =
      if length(rows) <= prefilter do
        rows
      else
        rows
        |> Enum.filter(&(vec(&1, :embed64) != []))
        |> Enum.map(fn r -> {Embed.cosine(qsmall, vec(r, :embed64)), r} end)
        |> top(prefilter)
        |> Enum.map(&elem(&1, 1))
      end

    candidates
    |> Enum.filter(&(vec(&1, :embed) != []))
    |> Enum.map(fn r -> Map.put(r, :score, Embed.cosine(qfull, vec(r, :embed))) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

  @doc "Embed `query` and `top_k` over all rows of `mod` in the Store."
  @spec search(String.t(), module, pos_integer, keyword) :: [map]
  def search(query, mod, k, opts \\ []) do
    tenant = opts[:tenant]
    rows = if tenant, do: Store.all(mod, tenant), else: Store.all(mod)
    top_k(rows, Index.embed_query(query, opts), k, opts)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp top(scored, n), do: scored |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.take(n)
  defp vec(row, key), do: Map.get(row, key) || []
end
