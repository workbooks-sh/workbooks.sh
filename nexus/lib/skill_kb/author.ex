defmodule Nexus.SkillKB.Author do
  @moduledoc """
  S7 recall + author-on-demand — the inversion's payoff.

  A topic query ranks the **obfuscated** `Capability` layer first, pulls the best leaf chunks within
  the member skills (small-to-big), expands 1-hop over the `Edge` graph, then an **injectable author**
  (`opts[:author]`, default `Nexus.Llm`) writes a *fresh, targeted* `.work` skill grounded in that
  context — never a verbatim copy. Drill-down stays available: the result carries the source skill
  slugs and their provenance hashes (mixed-license inherits the most restrictive license).

  The author fn is a seam (like S6's synth) so recall is testable without a live model.
  """

  alias Nexus.{Store, SkillKB.Recall, SkillKB.Graph}

  @doc """
  Author a skill for `topic`. `mods` = `%{cap, unit, chunk, edge}` (resource modules). Returns
  `%{skill: work_string, capability: map | nil, sources: [slug], license: atom}`.
  """
  @spec author_for(String.t(), map, keyword) :: map
  def author_for(topic, mods, opts \\ []) do
    tenant = opts[:tenant]
    author = opts[:author] || (&default_author/2)

    caps = Recall.search(topic, mods.cap, opts[:caps] || 3, tenant: tenant)
    cap = List.first(caps)

    member_slugs = members_of(caps, mods.unit, tenant)
    leaves = candidate_chunks(topic, mods.chunk, member_slugs, opts[:leaves] || 8, tenant)
    %{neighbors: neighbors} = Graph.expand(leaves, mods.edge, tenant: tenant)

    sources = (leaves |> Enum.map(& &1.skill)) |> Enum.concat(neighbors) |> Enum.uniq()
    units = source_units(sources, mods.unit, tenant)

    context = build_context(cap, leaves, units)
    skill = author.(topic, context)

    %{
      skill: skill,
      capability: cap && %{name: cap.name, summary: cap.summary},
      sources: sources,
      license: license_of(units)
    }
  end

  # ── recall helpers ──────────────────────────────────────────────────────────

  # Member skills of the recalled capabilities (the obfuscation → concrete bridge).
  defp members_of([], _unit_mod, _tenant), do: MapSet.new()

  defp members_of(caps, unit_mod, tenant) do
    cids = MapSet.new(caps, & &1.cid)
    all(unit_mod, tenant) |> Enum.filter(&MapSet.member?(cids, &1.capability)) |> MapSet.new(& &1.slug)
  end

  # Best leaf chunks, restricted to the member skills when we have them, else corpus-wide.
  defp candidate_chunks(topic, chunk_mod, member_slugs, k, tenant) do
    rows = all(chunk_mod, tenant)
    rows = if MapSet.size(member_slugs) > 0, do: Enum.filter(rows, &MapSet.member?(member_slugs, &1.skill)), else: rows
    Recall.top_k(rows, Nexus.SkillKB.Index.embed_query(topic, []), k, [])
  end

  defp source_units(slugs, unit_mod, tenant) do
    set = MapSet.new(slugs)
    all(unit_mod, tenant) |> Enum.filter(&MapSet.member?(set, &1.slug))
  end

  # ── authoring ───────────────────────────────────────────────────────────────

  defp build_context(cap, leaves, units) do
    %{
      capability: cap && cap.summary,
      provenance: Enum.map(units, &{&1.slug, &1.weave_hash}),
      excerpts: Enum.map(leaves, fn l -> %{skill: l.skill, anchor: l.anchor, text: l.text} end)
    }
  end

  defp default_author(topic, ctx) do
    excerpts =
      ctx.excerpts
      |> Enum.map(fn e -> "### #{e.skill} — #{e.anchor}\n#{e.text}" end)
      |> Enum.join("\n\n")
      |> String.slice(0, 8000)

    prompt = """
    Author a single focused `.work` skill that helps with: #{topic}

    Ground it in the reference material below — synthesize a fresh, targeted skill; do NOT copy any
    one source verbatim. Output ONLY the `.work` content: a `# title`, a one-paragraph intro, an
    `app :slug do title "…" description "…" end` block, then `## ` sections with concise steps and
    fenced example commands. Keep it content-only (no scripts to run).

    Capability context: #{ctx.capability}

    Reference material:
    #{excerpts}
    """

    case Nexus.Llm.complete([%{role: "user", content: prompt}], max_tokens: 1200) do
      {:ok, %{content: c}} when is_binary(c) and c != "" -> String.trim(c)
      _ -> fallback_skill(topic, ctx)
    end
  end

  # Deterministic fallback when no model is reachable — still a valid, grounded `.work` skill.
  defp fallback_skill(topic, ctx) do
    slug = topic |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    sections = ctx.excerpts |> Enum.map(fn e -> "## #{e.anchor}\n\n#{e.text}" end) |> Enum.join("\n\n")

    """
    # #{topic}

    Authored for "#{topic}" from #{length(ctx.excerpts)} recalled reference(s).

    app :authored__#{slug} do
      title       "#{topic}"
      description "Authored on demand for: #{topic}."
    end

    #{sections}
    """
  end

  defp license_of(units) do
    licenses = units |> Enum.map(&Map.get(&1, :license, :permissive)) |> Enum.uniq()
    cond do
      :proprietary in licenses -> :proprietary
      :copyleft in licenses -> :copyleft
      :permissive in licenses -> :permissive
      true -> :cc0
    end
  end

  defp all(mod, nil), do: Store.all(mod)
  defp all(mod, tenant), do: Store.all(mod, tenant)
end
