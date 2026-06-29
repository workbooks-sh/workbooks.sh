defmodule Nexus.SkillKB do
  @moduledoc """
  Inverted skill registry → a semantic capability knowledge-base that authors targeted `.work` skills
  on demand. This top module is the Phase-0 orchestrator: it ties `Triage` → `Convert` → `Audit` into
  one corpus build that lowers the curated source corpus to clean, content-only native `.work`.

  Pipeline per source skill:

    1. **Triage** the source `.md`/`SKILL.md` → `:convert` | `:content_only` | `:exclude`.
    2. `:exclude` → recorded, never converted.
    3. `:convert` / `:content_only` in the toolkit `.md` format → **Convert** to `.work`, then **Audit**:
       * audit `:block` → demoted to excluded-by-audit (kept out of the KB).
       * audit `:pass` → write the **stripped** `.work` (platform coupling removed) to the corpus.
    4. Non-toolkit (`SKILL.md` frontmatter) content-only skills (e.g. impeccable) are recorded
       `:manual` — they need a hand pass and are not auto-converted (deliberately low-risk).

  Downstream slices (S2+) read the corpus `.work` back via `Nexus.Literate` into `Nexus.Store`.
  """

  alias Nexus.SkillKB.{Triage, Convert, Audit}

  @doc """
  Build the converted corpus under `out_root`. Returns a report map with per-bucket tallies and the
  list of written paths. The one IO-heavy seam.

  Sources: `toolkits/*/skills/*.md` (toolkit format) + `.claude/skills/*/SKILL.md` (frontmatter).
  """
  @spec build_corpus(String.t(), keyword) :: map
  def build_corpus(out_root \\ "dogfood/skill-kb/corpus", _opts \\ []) do
    sources = gather()
    entries = Enum.map(sources, &triage_one/1)

    File.mkdir_p!(out_root)
    File.write!(Path.join(Path.dirname(out_root), "triage.work"), Triage.manifest_work(Enum.map(entries, & &1.triage)))

    results = Enum.map(entries, &process(&1, out_root))

    report = Enum.frequencies_by(results, & &1.outcome)
    written = results |> Enum.filter(&(&1.outcome == :written)) |> Enum.map(& &1.path)

    %{
      total: length(results),
      tally: report,
      written: written,
      blocked: results |> Enum.filter(&(&1.outcome == :blocked)) |> Enum.map(&{&1.name, &1.reasons}),
      manual: results |> Enum.filter(&(&1.outcome == :manual)) |> Enum.map(& &1.name),
      excluded: results |> Enum.filter(&(&1.outcome == :excluded)) |> Enum.map(& &1.name)
    }
  end

  # ── gather + triage ──────────────────────────────────────────────────────

  defp gather do
    toolkit =
      Path.wildcard("toolkits/*/skills/*.md")
      |> Enum.map(fn p ->
        %{path: p, name: Path.basename(p, ".md"), toolkit: p |> Path.dirname() |> Path.dirname() |> Path.basename(), format: :toolkit}
      end)

    claude =
      Path.wildcard(".claude/skills/*/SKILL.md")
      |> Enum.map(fn p ->
        dir = Path.dirname(p)
        %{path: p, name: Path.basename(dir), toolkit: "claude", format: :frontmatter, has_scripts: File.dir?(Path.join(dir, "scripts"))}
      end)

    toolkit ++ claude
  end

  defp triage_one(src) do
    text = File.read!(src.path)
    t = Triage.classify(src.name, text, toolkit: src.toolkit, has_scripts: src[:has_scripts] || false)
    Map.merge(src, %{text: text, triage: t})
  end

  # ── process one skill ──────────────────────────────────────────────────────

  defp process(%{triage: %{bucket: :exclude}} = e, _out),
    do: %{name: qualified(e), outcome: :excluded, reasons: e.triage.reasons}

  # Non-toolkit (frontmatter) skills need a hand pass — never auto-convert.
  defp process(%{format: :frontmatter} = e, _out),
    do: %{name: qualified(e), outcome: :manual, reasons: e.triage.reasons}

  defp process(%{format: :toolkit} = e, out_root) do
    {_slug, work, _meta} = Convert.to_work(e.text, e.toolkit)

    case Audit.audit(work) do
      %{verdict: :block, findings: f} ->
        %{name: qualified(e), outcome: :blocked, reasons: Enum.filter(f, &(&1.action == :block)) |> Enum.map(& &1.category)}

      %{verdict: :pass, stripped_text: clean} ->
        dir = Path.join(out_root, e.toolkit)
        File.mkdir_p!(dir)
        path = Path.join(dir, e.name <> ".work")
        File.write!(path, clean)
        %{name: qualified(e), outcome: :written, path: path, reasons: []}
    end
  end

  defp qualified(e), do: "#{e.toolkit}/#{e.name}"
end
