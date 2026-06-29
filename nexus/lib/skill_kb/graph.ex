defmodule Nexus.SkillKB.Graph do
  @moduledoc """
  S5 dependency graph: harvest `Edge` rows free from the prose backlinks the converter preserved, and
  expand a set of retrieval leaves to their parents + 1-hop neighbors.

  GraphRAG's edge benefit without its per-document LLM extraction cost: the graph is already authored
  in the source as `[[…]]` / `work://` / `:atom` / `#tag` references (normalized to clean basenames at
  ingest). `harvest/4` resolves each chunk's refs to a target `SkillUnit` via its `origin_path`
  basename and writes one `Edge` per resolved link. Unresolved refs are dropped (a ref may point
  outside the curated corpus). `expand/4` is the recall-time fan-out used by S7.
  """

  alias Nexus.Store

  @doc """
  Build `Edge` rows from every `RefChunk`'s refs. Returns `{edges_written, unresolved}`.

  `src` = the chunk's skill slug, `dst` = the resolved target unit slug. Resolution maps a ref
  basename (e.g. `undo-a-commit-safely`) to the unit whose `origin_path` basename matches.
  """
  @spec harvest(module, module, module, keyword) :: {non_neg_integer, non_neg_integer}
  def harvest(unit_mod, chunk_mod, edge_mod, opts \\ []) do
    tenant = opts[:tenant]
    by_base = base_index(all(unit_mod, tenant))

    {written, unresolved} =
      all(chunk_mod, tenant)
      |> Enum.flat_map(fn c -> Enum.map(refs_of(c), &{c.skill, &1}) end)
      |> Enum.reduce({0, 0}, fn {src, ref}, {w, u} ->
        case Map.get(by_base, ref) do
          nil ->
            {w, u + 1}

          dst when dst == src ->
            {w, u}

          dst ->
            create(edge_mod, %{src: src, dst: dst, kind: :backlink, weight: 1.0}, tenant)
            {w + 1, u}
        end
      end)

    {written, unresolved}
  end

  @doc """
  Expand retrieval leaves: return `%{units: [slug], neighbors: [slug]}` — the parent skill of each
  leaf, plus the 1-hop `Edge` neighbors of those skills (both directions).
  """
  @spec expand([map], module, keyword) :: %{units: [String.t()], neighbors: [String.t()]}
  def expand(leaves, edge_mod, opts \\ []) do
    tenant = opts[:tenant]
    units = leaves |> Enum.map(& &1.skill) |> Enum.uniq()
    set = MapSet.new(units)

    neighbors =
      all(edge_mod, tenant)
      |> Enum.flat_map(fn e ->
        cond do
          MapSet.member?(set, e.src) -> [e.dst]
          MapSet.member?(set, e.dst) -> [e.src]
          true -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(set, &1))

    %{units: units, neighbors: neighbors}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp base_index(units) do
    Map.new(units, fn u -> {u.origin_path |> Path.basename(".work"), u.slug} end)
  end

  defp refs_of(%{refs: refs}) when is_list(refs), do: refs
  defp refs_of(_), do: []

  defp all(mod, nil), do: Store.all(mod)
  defp all(mod, tenant), do: Store.all(mod, tenant)
  defp create(mod, attrs, nil), do: Store.create(mod, attrs)
  defp create(mod, attrs, tenant), do: Store.create(mod, attrs, tenant)
end
