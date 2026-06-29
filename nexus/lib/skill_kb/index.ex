defmodule Nexus.SkillKB.Index do
  @moduledoc """
  S4 embedding: fill the two Matryoshka vector slices on each KB row via the `Nexus.Embed` seam.

  **P2 contextual chunking** — each `RefChunk` is embedded with its skill slug + section anchor
  prepended (`[skill: …] [section: …] <text>`), a zero-query-latency recall lift on technical text.
  **P1 two-tier (MRL)** — `embed` is the full vector; `embed64` is the first 64 dims re-normalized, a
  cheap pre-filter so `Recall.top_k/4` stays sub-50ms without an ANN index. Under the bootstrap
  `Nexus.Embed.Hashed` provider this is a mechanical pre-filter; it becomes true Matryoshka once an
  MRL model lands at the model-swap point (S8). Re-embedding is idempotent — safe to re-run on a batch.
  """

  alias Nexus.{Embed, Store}

  @prefilter_dim 64

  @doc "Embed every `RefChunk` row (contextual) and persist `embed`/`embed64`. Returns the count."
  @spec embed_chunks(module, keyword) :: non_neg_integer
  def embed_chunks(chunk_mod, opts \\ []) do
    tenant = opts[:tenant]

    rows(chunk_mod, tenant)
    |> Enum.map(fn c ->
      {full, small} = embed_text(contextual(c), opts)
      Store.update(chunk_mod, %{skill: c.skill, anchor: c.anchor}, %{embed: full, embed64: small}, tenant)
    end)
    |> length()
  end

  @doc "Embed every `SkillUnit` (title + description) and persist its slices. Returns the count."
  @spec embed_units(module, keyword) :: non_neg_integer
  def embed_units(unit_mod, opts \\ []) do
    tenant = opts[:tenant]

    rows(unit_mod, tenant)
    |> Enum.map(fn u ->
      {full, small} = embed_text("#{u.title}. #{u.description}", opts)
      Store.update(unit_mod, %{slug: u.slug}, %{embed: full, embed64: small}, tenant)
    end)
    |> length()
  end

  @doc "Embed one query string → `{full, embed64}` (same transform as the rows, for symmetric recall)."
  @spec embed_query(String.t(), keyword) :: {[float], [float]}
  def embed_query(q, opts \\ []), do: embed_text(q, opts)

  @doc "First-64-dims-renormalized slice of a full unit vector (the MRL pre-filter tier)."
  @spec truncate(list, pos_integer) :: [float]
  def truncate(vec, dim \\ @prefilter_dim), do: vec |> Enum.take(dim) |> l2()

  # ── internals ──────────────────────────────────────────────────────────────

  defp contextual(c), do: "[skill: #{c.skill}] [section: #{c.anchor}] #{c.text}"

  defp embed_text(text, opts) do
    full = Embed.embed_one(text, opts)
    {full, truncate(full)}
  end

  defp rows(mod, nil), do: Store.all(mod)
  defp rows(mod, tenant), do: Store.all(mod, tenant)

  defp l2(vec) do
    norm = vec |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
    if norm == 0.0, do: vec, else: Enum.map(vec, &(&1 / norm))
  end
end
