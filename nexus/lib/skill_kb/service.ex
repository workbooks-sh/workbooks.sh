defmodule Nexus.SkillKB.Service do
  @moduledoc """
  Runtime entry point for the Skill-KB — the self-contained service the cloud routes call.

  It owns the four KB resources (compiled once from the shipped `index.work`, cached in
  `:persistent_term`), lazily **builds the index** per tenant (ingest the shipped corpus → embed via
  the configured `Nexus.Embed` provider → cluster → harvest edges) the first time it's asked, then
  serves `recall/2`, `author/2`, and `stats/1`. Idempotent: a built tenant is detected by a non-empty
  store and skipped.

  Paths default to the in-repo `dogfood/skill-kb` tree and are overridable via `Nexus.Config`
  (`:skill_kb_root`) so the deployed image can point at wherever the corpus ships.
  """

  alias Nexus.{Store, SkillKB.Ingest, SkillKB.Index, SkillKB.Cluster, SkillKB.Graph, SkillKB.Recall, SkillKB.Author}

  @pt_mods {__MODULE__, :mods}
  @default_root "dogfood/skill-kb"

  @doc "The compiled resource modules `%{unit, chunk, cap, edge}` (compiled + cached on first use)."
  def mods do
    case :persistent_term.get(@pt_mods, nil) do
      nil ->
        m = compile_resources()
        :persistent_term.put(@pt_mods, m)
        m

      m ->
        m
    end
  end

  @doc "Ensure the KB is ingested + embedded + clustered for `tenant`. Idempotent. Returns stats."
  @spec ensure_built(String.t(), keyword) :: map
  def ensure_built(tenant, opts \\ []) do
    %{unit: u, chunk: c, cap: cap, edge: e} = mods()

    if Store.count(u, tenant) == 0 or opts[:rebuild] do
      if opts[:rebuild], do: Enum.each([u, c, cap, e], &Store.clear(&1, tenant))

      Ingest.from_corpus(corpus_dir(), unit: u, chunk: c, tenant: tenant)
      Index.embed_chunks(c, tenant: tenant)
      Index.embed_units(u, tenant: tenant)
      synth = opts[:synth] || if(opts[:llm_summaries], do: &summarize/2, else: &name_summary/2)
      Cluster.rebuild(u, c, cap, tenant: tenant, synth: synth)
      Graph.harvest(u, c, e, tenant: tenant)
    end

    stats(tenant)
  end

  @doc """
  Recall for a topic: the obfuscated capability + the best source chunks (drill-down). Builds lazily.
  Returns `%{capability, hits: [%{skill, anchor, score, text, lane}]}`.
  """
  @spec recall(String.t(), keyword) :: map
  def recall(query, opts \\ []) do
    tenant = tenant(opts)
    ensure_built(tenant, opts)
    %{unit: u, chunk: c, cap: cap} = mods()

    hits =
      Recall.search(query, c, opts[:k] || 8, tenant: tenant)
      |> Enum.map(fn h ->
        %{skill: h.skill, anchor: h.anchor, score: Float.round(h.score, 3), lane: h.lane, text: snippet(h.text)}
      end)

    top_cap = Recall.search(query, cap, 1, tenant: tenant) |> List.first()

    %{
      query: query,
      capability: top_cap && %{name: top_cap.name, summary: top_cap.summary, skill_count: top_cap.skill_count},
      hits: hits,
      sources: hits |> Enum.map(& &1.skill) |> Enum.uniq() |> Enum.map(&unit_card(&1, u, tenant))
    }
  end

  @doc "Author a fresh, targeted `.work` skill grounded in recalled context. Builds lazily."
  @spec author(String.t(), keyword) :: map
  def author(query, opts \\ []) do
    tenant = tenant(opts)
    ensure_built(tenant, opts)
    m = mods()
    Author.author_for(query, %{cap: m.cap, unit: m.unit, chunk: m.chunk, edge: m.edge}, tenant: tenant)
  end

  @doc "Corpus stats for the showcase header."
  @spec stats(String.t() | keyword) :: map
  def stats(opts) when is_list(opts), do: stats(tenant(opts))

  def stats(tenant) when is_binary(tenant) do
    %{unit: u, chunk: c, cap: cap, edge: e} = mods()

    %{
      skills: Store.count(u, tenant),
      chunks: Store.count(c, tenant),
      capabilities: Store.count(cap, tenant),
      edges: Store.count(e, tenant),
      built: Store.count(u, tenant) > 0
    }
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp compile_resources do
    decls =
      Path.join(root(), "index.work")
      |> File.read!()
      |> Nexus.Literate.parse()
      |> Enum.filter(&(&1.type == :code and Map.get(&1, :kind) == "resource"))

    by_name = Map.new(decls, fn d -> {d.name, Nexus.Resource.compile(d)} end)
    %{unit: by_name["SkillUnit"], chunk: by_name["RefChunk"], cap: by_name["Capability"], edge: by_name["Edge"]}
  end

  defp name_summary(names, _texts), do: "Covers: " <> Enum.join(Enum.take(names, 6), "; ") <> "."

  defp summarize(names, _texts) do
    prompt = "Write a 2-sentence capability summary for these related skills: #{Enum.join(Enum.take(names, 6), ", ")}."

    case Nexus.Llm.complete([%{role: "user", content: prompt}], max_tokens: 120) do
      {:ok, %{content: c}} when is_binary(c) and c != "" -> String.trim(c)
      _ -> "Covers: #{Enum.join(Enum.take(names, 6), "; ")}."
    end
  end

  defp unit_card(slug, unit_mod, tenant) do
    case Store.all(unit_mod, tenant) |> Enum.find(&(&1.slug == slug)) do
      nil -> %{slug: slug, title: slug, network: false, destructive: false}
      u -> %{slug: u.slug, title: u.title, description: u.description, origin: u.origin_path, network: net?(u), destructive: dest?(u)}
    end
  end

  defp net?(u), do: String.contains?(u.description || "", "NETWORK")
  defp dest?(u), do: String.contains?(u.description || "", "DESTRUCTIVE")
  defp snippet(t), do: t |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)

  defp tenant(opts), do: opts[:tenant] || "skillkb"
  defp corpus_dir, do: Path.join(root(), "corpus")

  # Resolve the skill-kb tree: config override first, else the first existing candidate (works from the
  # repo root, from nexus/ under mix, or from the deployed app dir).
  defp root do
    candidates =
      [cfg(:skill_kb_root), @default_root, Path.join("..", @default_root), Path.join(:code.priv_dir(:nexus) |> to_string(), "skill-kb")]
      |> Enum.filter(&is_binary/1)

    Enum.find(candidates, hd(candidates), fn p -> File.exists?(Path.join(p, "index.work")) end)
  end

  defp cfg(key) do
    if Code.ensure_loaded?(Nexus.Config) and function_exported?(Nexus.Config, :get, 1), do: Nexus.Config.get(key)
  rescue
    _ -> nil
  end
end

# (deployed to the dogfood nexus runtime — Toolkits → Skills KB)
