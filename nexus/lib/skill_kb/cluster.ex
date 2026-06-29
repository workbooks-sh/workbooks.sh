defmodule Nexus.SkillKB.Cluster do
  @moduledoc """
  S6 capability layer: cluster ingested skills and synthesize one RAPTOR-style summary per cluster —
  the obfuscation surface that recall hits first.

  Research trimmed RAPTOR to a *single* abstraction level at hundreds-of-docs scale, so this builds one
  `Capability` per cluster, not a deep tree. Clustering is greedy agglomerative over `SkillUnit.embed`
  (cosine ≥ `:threshold` joins the nearest existing cluster, else a new one) — pure and deterministic,
  no k chosen up front. The per-cluster summary comes from an **injectable synthesizer**
  (`opts[:synth]`, default `Nexus.Llm`), mirroring the `Nexus.Embed` seam so tests stay LLM-free and
  the model is swappable. Each unit is back-linked to its capability via `capability:`.
  """

  alias Nexus.{Embed, Store, SkillKB.Index}

  @threshold 0.55

  @doc """
  (Re)build the capability layer. Clusters units, synthesizes + embeds one `Capability` per cluster,
  and stamps each unit's `capability`. Returns the list of capability ids. Idempotent (clears first).
  """
  @spec rebuild(module, module, module, keyword) :: [String.t()]
  def rebuild(unit_mod, chunk_mod, cap_mod, opts \\ []) do
    tenant = opts[:tenant]
    synth = opts[:synth] || (&default_synth/2)
    threshold = opts[:threshold] || @threshold

    units = all(unit_mod, tenant) |> Enum.filter(&(vec(&1) != []))
    clusters = cluster(units, threshold)

    Store.clear(cap_mod, tenant)

    clusters
    |> Enum.with_index(1)
    |> Enum.map(fn {members, i} ->
      id = "cap_#{i}"
      texts = member_texts(members, chunk_mod, tenant)
      summary = synth.(member_names(members), texts)
      {full, small} = Index.embed_query(summary, opts)

      create(cap_mod, %{
        cid: id,
        name: name_for(members),
        summary: summary,
        embed: full,
        embed64: small,
        tags: [],
        license: :permissive,
        skill_count: length(members)
      }, tenant)

      Enum.each(members, &Store.update(unit_mod, %{slug: &1.slug}, %{capability: id}, tenant))
      id
    end)
  end

  @doc "Greedy agglomerative clustering of rows by `embed` cosine. Pure; exposed for testing."
  @spec cluster([map], float) :: [[map]]
  def cluster(units, threshold \\ @threshold) do
    Enum.reduce(units, [], fn u, clusters ->
      case best_cluster(clusters, u, threshold) do
        nil -> clusters ++ [[u]]
        idx -> List.update_at(clusters, idx, &[u | &1])
      end
    end)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp best_cluster(clusters, u, threshold) do
    clusters
    |> Enum.with_index()
    |> Enum.map(fn {members, i} -> {centroid_sim(members, u), i} end)
    |> Enum.filter(fn {sim, _} -> sim >= threshold end)
    |> case do
      [] -> nil
      sims -> sims |> Enum.max_by(&elem(&1, 0)) |> elem(1)
    end
  end

  defp centroid_sim(members, u) do
    members |> Enum.map(&Embed.cosine(vec(&1), vec(u))) |> avg()
  end

  defp member_texts(members, chunk_mod, tenant) do
    slugs = MapSet.new(members, & &1.slug)

    all(chunk_mod, tenant)
    |> Enum.filter(&MapSet.member?(slugs, &1.skill))
    |> Enum.map(& &1.text)
    |> Enum.join("\n\n")
  end

  defp member_names(members), do: Enum.map(members, & &1.title)
  defp name_for(members), do: members |> Enum.map(& &1.title) |> List.first() |> Kernel.||("capability")

  # Default synthesizer: ask the LLM for a capability abstract over the member skills. Returns plain
  # text. Falls back to a deterministic stub when no model is reachable (e.g. no API key) so ingest
  # never hard-fails on a missing key.
  defp default_synth(names, texts) do
    prompt =
      "Write a 2-3 sentence capability summary covering what these related skills collectively let " <>
        "someone do. Skills: #{Enum.join(names, ", ")}.\n\nReference material:\n#{String.slice(texts, 0, 6000)}"

    case Nexus.Llm.complete([%{role: "user", content: prompt}], max_tokens: 200) do
      {:ok, %{content: c}} when is_binary(c) and c != "" -> String.trim(c)
      _ -> "Capability covering: #{Enum.join(names, "; ")}."
    end
  end

  defp all(mod, nil), do: Store.all(mod)
  defp all(mod, tenant), do: Store.all(mod, tenant)
  defp create(mod, attrs, nil), do: Store.create(mod, attrs)
  defp create(mod, attrs, tenant), do: Store.create(mod, attrs, tenant)
  defp vec(row), do: Map.get(row, :embed) || []
  defp avg([]), do: 0.0
  defp avg(xs), do: Enum.sum(xs) / length(xs)
end
