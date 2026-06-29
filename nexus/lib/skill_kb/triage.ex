defmodule Nexus.SkillKB.Triage do
  @moduledoc """
  Phase-0 triage (0a): classify each source skill before bulk conversion.

  Scope is a **curated subset** (locked decision): convert broadly-useful general skills, exclude
  Workbooks-internal meta/procedural skills. Each skill lands in one bucket:

    * `:convert`      — clean general-domain how-to (git, ffmpeg). Convert as-is.
    * `:content_only` — useful but script/orchestration-coupled (e.g. a skill with a `scripts/` dir or
      `node …/scripts/*.mjs` invocations). Convert the capability *knowledge*; the strip pass drops the
      coupling.
    * `:exclude`      — Workbooks-internal meta / platform plumbing with no general value
      (conformance-ladder, js-ecosystem-loop, washy-transpiler, docs-authoring, the `*-autoloop`
      skills, anything leaning on internal `Workbooks.*` / `Nexus.*` APIs or `bd`/beads).

  Excludes are recorded with a reason, never deleted. `manifest_work/1` renders the classification as
  an eyeball-able `.work` table. Pure: no IO.
  """

  # Names/slugs known to be internal regardless of content.
  @exclude_names ~w(
    conformance-ladder js-ecosystem-loop washy-transpiler docs-authoring
    impeccable-internal worg-autoloop watershed-autoloop adbuy-autoloop wbx-autoloop
  )

  # Content signals that a skill is Workbooks-internal (off-domain for a general KB).
  @internal_signals [
    ~r/\bWorkbooks\.[A-Z]\w+/,
    ~r/\bNexus\.[A-Z]\w+/,
    ~r/\bPorffor\b|\bWashy\b|\bwasm sandbox\b/i,
    ~r/\bbd (ready|show|update|close|prime|memories)\b/,
    ~r/\bbeads\b/i,
    ~r/\bconformance ladder\b|\brung\b.{0,20}\bladder\b/i,
    ~r/\.work\b.{0,20}\b(file|workbook|reactor)\b/,
    ~r/\bmix (test|compile)\b/
  ]

  # Content signals that a skill is useful but coupled (convert content-only, strip the coupling).
  @coupled_signals [
    ~r/\bnode\b[^\n]*\bscripts\/[^\n]*\.mjs/,
    ~r/\bnpx?\b\s+\w/,
    ~r/\.claude\/skills/,
    ~r/\b(wrangler|vercel|fly)\b/i
  ]

  @type bucket :: :convert | :content_only | :exclude
  @type entry :: %{name: String.t(), toolkit: String.t() | nil, bucket: bucket, reasons: [String.t()], has_scripts: boolean}

  @doc """
  Classify one skill from its `name`, source `text`, and whether it has a sibling `scripts/` dir.
  """
  @spec classify(String.t(), String.t(), keyword) :: entry
  def classify(name, text, opts \\ []) do
    toolkit = opts[:toolkit]
    has_scripts = opts[:has_scripts] || false

    internal = match_reasons(text, @internal_signals, "internal")
    coupled = match_reasons(text, @coupled_signals, "coupled")
    name_excluded = Enum.any?(@exclude_names, &String.contains?(name, &1))

    {bucket, reasons} =
      cond do
        name_excluded -> {:exclude, ["name on internal exclude-list" | internal]}
        internal != [] -> {:exclude, internal}
        has_scripts -> {:content_only, ["has scripts/ dir" | coupled]}
        coupled != [] -> {:content_only, coupled}
        true -> {:convert, []}
      end

    %{name: name, toolkit: toolkit, bucket: bucket, reasons: reasons, has_scripts: has_scripts}
  end

  @doc "Render a list of entries as a `.work` manifest with a markdown table (eyeball-able, no JSON)."
  @spec manifest_work([entry]) :: String.t()
  def manifest_work(entries) do
    counts = Enum.frequencies_by(entries, & &1.bucket)

    rows =
      entries
      |> Enum.sort_by(&{bucket_rank(&1.bucket), &1.toolkit, &1.name})
      |> Enum.map(fn e ->
        "| #{e.name} | #{e.toolkit || "—"} | #{e.bucket} | #{Enum.join(e.reasons, "; ") |> blank_dash()} |"
      end)

    """
    # Skill-KB — Phase-0 triage manifest

    Auto-generated classification of the curated skill corpus before conversion. `convert` = clean
    general how-to; `content_only` = useful but coupled (strip the coupling); `exclude` = Workbooks-internal.
    Excludes are recorded, not deleted.

    Tally: #{Map.get(counts, :convert, 0)} convert · #{Map.get(counts, :content_only, 0)} content-only · #{Map.get(counts, :exclude, 0)} exclude.

    | Skill | Toolkit | Bucket | Reasons |
    | --- | --- | --- | --- |
    #{Enum.join(rows, "\n")}
    """
  end

  defp match_reasons(text, patterns, tag) do
    for re <- patterns, Regex.match?(re, text), do: "#{tag}: #{Regex.run(re, text) |> List.first() |> String.trim() |> String.slice(0, 48)}"
  end

  defp bucket_rank(:convert), do: 0
  defp bucket_rank(:content_only), do: 1
  defp bucket_rank(:exclude), do: 2
  defp blank_dash(""), do: "—"
  defp blank_dash(s), do: s
end
