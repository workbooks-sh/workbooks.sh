defmodule Nexus.SkillKB.Ingest do
  @moduledoc """
  S2 ingest: read a converted `.work` skill back into KB rows (`SkillUnit` + `RefChunk`).

  Each converted skill is one `.work` file: an `app :slug do title/description end` decl carrying the
  unit metadata, followed by `## ` section headings whose bodies are the small-to-big retrieval
  **leaves**. `parse/2` is the pure transform (text → `{unit, [chunks]}`); `from_work/2` persists via
  `Nexus.Store`. Parsing uses `Nexus.Literate` so the KB and the authoring surface share one parser.
  """

  alias Nexus.Literate

  @doc """
  Pure transform: a converted `.work` skill string → `{unit_map, [chunk_map]}`.

  `unit_map` keys: `:slug, :title, :description, :toolkit, :origin_path, :network, :destructive,
  :weave_hash, :refs`. Each `chunk_map`: `:skill, :anchor, :lane, :text, :parent, :refs`.
  """
  @spec parse(String.t(), keyword) :: {map, [map]}
  def parse(text, opts \\ []) when is_binary(text) do
    blocks = Literate.parse(text)
    unit = unit_from(text, blocks, opts)
    chunks = chunks_from(blocks, unit.slug)
    {%{unit | refs: chunks |> Enum.flat_map(& &1.refs) |> Enum.uniq()}, chunks}
  end

  @doc """
  Read + persist one converted skill file. Writes one `SkillUnit` and N `RefChunk` rows via
  `Nexus.Store`. `resources` maps `:unit`/`:chunk` to the compiled resource modules (from `kb.work`).
  Returns `{:ok, slug, chunk_count}`.
  """
  @spec from_work(String.t(), keyword) :: {:ok, String.t(), non_neg_integer} | {:blocked, String.t(), [String.t()]}
  def from_work(path, opts) do
    {unit_mod, chunk_mod} = {Keyword.fetch!(opts, :unit), Keyword.fetch!(opts, :chunk)}
    tenant = opts[:tenant]
    toolkit = opts[:toolkit] || (path |> Path.dirname() |> Path.basename())

    work = File.read!(path)
    {unit, chunks} = parse(work, toolkit: toolkit, origin_path: path)

    # S3 gate (re-verify at ingest): a blocked skill never gets persisted, so it stays unrecallable.
    case Nexus.SkillKB.Audit.run(work) do
      {:block, reasons} ->
        {:blocked, unit.slug, reasons}

      {:ok, score} ->
        store(unit_mod, unit_attrs(unit, score), tenant)
        Enum.each(chunks, &store(chunk_mod, chunk_attrs(&1), tenant))
        {:ok, unit.slug, length(chunks)}
    end
  end

  @doc """
  Ingest every `*.work` under a corpus dir tree. Returns `[{slug, chunk_count}]` for the skills that
  passed the S3 gate; blocked skills are skipped (not persisted) and reported via `Logger`.
  """
  @spec from_corpus(String.t(), keyword) :: [{String.t(), non_neg_integer}]
  def from_corpus(corpus_root, opts) do
    Path.wildcard(Path.join(corpus_root, "**/*.work"))
    |> Enum.flat_map(fn p ->
      case from_work(p, Keyword.put(opts, :toolkit, p |> Path.dirname() |> Path.basename())) do
        {:ok, slug, n} -> [{slug, n}]
        {:blocked, slug, reasons} -> require Logger; Logger.warning("skill-kb: blocked #{slug}: #{inspect(reasons)}"); []
      end
    end)
  end

  # ── unit ────────────────────────────────────────────────────────────────

  # `app :slug do … end` parses as a kind-with-name *code* block, so extract the metadata by regex on
  # the raw source rather than relying on a `:decl` node.
  defp unit_from(text, blocks, opts) do
    slug = capture(text, ~r/app\s+:([a-zA-Z0-9_]+)/) || "unknown"
    title = capture(text, ~r/title\s+"([^"]*)"/) || slug
    desc = capture(text, ~r/description\s+"((?:[^"\\]|\\.)*)"/) || ""
    _ = blocks

    %{
      slug: slug,
      title: title,
      description: desc,
      toolkit: opts[:toolkit],
      origin_path: opts[:origin_path],
      network: String.contains?(desc, "NETWORK"),
      destructive: String.contains?(desc, "DESTRUCTIVE"),
      weave_hash: hash(blocks),
      refs: []
    }
  end

  # ── chunks: one RefChunk per `## ` section ────────────────────────────────

  defp chunks_from(blocks, slug) do
    # Drop everything up to and including the app decl; section leaves come after.
    body = Enum.drop_while(blocks, fn b -> not (b.type == :heading and b.level == 2) end)

    body
    |> chunk_sections([], nil, [])
    |> Enum.map(fn {anchor, nodes} ->
      text = nodes |> Enum.map(& &1.text) |> Enum.join("\n\n") |> String.trim()
      %{
        skill: slug,
        anchor: anchor,
        lane: if(Enum.any?(nodes, &fenced?/1), do: :code, else: :prose),
        text: text,
        parent: nil,
        refs: nodes |> Enum.flat_map(&Map.get(&1, :refs, [])) |> Enum.map(&norm_ref/1) |> Enum.uniq()
      }
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  # Accumulate nodes under the current level-2 heading; a new level-2 heading starts a new section.
  defp chunk_sections([], acc, cur, nodes), do: finalize(acc, cur, nodes)

  defp chunk_sections([%{type: :heading, level: 2, text: t} | rest], acc, cur, nodes),
    do: chunk_sections(rest, finalize(acc, cur, nodes), t, [])

  defp chunk_sections([node | rest], acc, cur, nodes),
    do: chunk_sections(rest, acc, cur, [node | nodes])

  defp finalize(acc, nil, _nodes), do: acc
  defp finalize(acc, anchor, nodes), do: acc ++ [{anchor, Enum.reverse(nodes)}]

  # ── persistence attrs ─────────────────────────────────────────────────────

  defp unit_attrs(u, score) do
    %{
      slug: u.slug,
      title: u.title,
      description: u.description,
      source_kind: :work,
      origin_path: u.origin_path || "",
      capability: "",
      embed: [],
      embed64: [],
      weave_hash: u.weave_hash,
      provenance: [],
      audit: :passed,
      audit_score: score,
      obfuscated: true
    }
  end

  defp chunk_attrs(c) do
    %{skill: c.skill, anchor: c.anchor, lane: c.lane, text: c.text, embed: [], embed64: [], parent: c.parent || "", refs: c.refs || []}
  end

  defp store(mod, attrs, nil), do: Nexus.Store.create(mod, attrs)
  defp store(mod, attrs, tenant), do: Nexus.Store.create(mod, attrs, tenant)

  # ── utils ─────────────────────────────────────────────────────────────────

  # `[[target]]` / `[[target|alias]]` → `target` (clean Edge endpoint for S5).
  defp norm_ref(r), do: r |> String.trim() |> String.trim_leading("[[") |> String.trim_trailing("]]") |> String.split("|") |> List.first() |> String.trim()

  defp fenced?(%{text: t}), do: String.contains?(t, "```")
  defp capture(text, re), do: with([_, c] <- Regex.run(re, text || ""), do: c, else: (_ -> nil))
  defp hash(blocks), do: :crypto.hash(:sha256, :erlang.term_to_binary(blocks)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
