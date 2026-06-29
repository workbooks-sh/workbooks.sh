defmodule Nexus.SkillKB.Convert do
  @moduledoc """
  Phase-0 converter: a toolkit skill `.md` → a native `.work` skill file (content-only).

  The KB needs one parseable data structure, so every source skill is normalized to `.work` before
  ingest. This converter handles the toolkit `.md` shape:

      # <toolkit> — <title>
      # When to use this
      NETWORK: <yes|no>
      DESTRUCTIVE: <yes|no>
      <prose…>
      # <Section> / ## <N. step>
      ```bash …```
      # See also
      - [text](other-skill.md) — note

  It emits the dogfood-native skill shape proven valid by `work check`:

      # <title>

      <intro prose>

      app :<slug> do
        title       "<title>"
        description "<one-liner with NETWORK/DESTRUCTIVE folded in>"
      end

      ## <Section>
      <prose + fenced examples>

  **Content-only** (the locked decision): procedure stays as *reference text* and fenced examples,
  never as runnable steps. Markdown `[t](f.md)` links become `[[f]]` backlinks (the free Edge graph).
  Platform-coupling stripping is a separate pass (`Nexus.SkillKB.Audit`); this module is structure-only.
  """

  @doc """
  Convert one toolkit skill `.md` → `{slug, work_string, meta}`.

  `meta` is `%{title, network: bool, destructive: bool, toolkit, slug}` — carried onto the `SkillUnit`
  at ingest (S2). Pure: no filesystem, no app deps.
  """
  @spec to_work(String.t(), String.t()) :: {String.t(), String.t(), map}
  def to_work(md, toolkit) when is_binary(md) and is_binary(toolkit) do
    lines = String.split(md, "\n")
    {title, rest} = take_title(lines)
    {network, destructive, rest} = take_flags(rest)
    {intro, body_lines} = take_intro(rest)

    base = title |> strip_toolkit_prefix(toolkit)
    slug = slug_for(toolkit, title)
    desc = description(intro, base, network, destructive)
    body = render_body(body_lines)

    work =
      [
        "# #{title}",
        "",
        wrap(intro_or_default(intro, base)),
        "",
        "app :#{slug} do",
        ~s(  title       "#{escape(title)}"),
        ~s(  description "#{escape(desc)}"),
        "end",
        "",
        body
      ]
      |> Enum.join("\n")
      |> squeeze_blanks()

    {slug, work, %{title: title, network: network, destructive: destructive, toolkit: toolkit, slug: slug}}
  end

  @doc """
  Convert every `skills/*.md` in a toolkit directory → `.work` files in `out_dir`.

  Skips `overview.md` only if asked via `opts[:skip]`. Returns the list of `{slug, out_path, meta}`.
  Side-effecting (writes files) — the one IO seam, kept thin.
  """
  @spec convert_toolkit(String.t(), String.t(), keyword) :: [{String.t(), String.t(), map}]
  def convert_toolkit(toolkit_dir, out_dir, opts \\ []) do
    toolkit = Path.basename(toolkit_dir)
    skip = MapSet.new(opts[:skip] || [])
    File.mkdir_p!(out_dir)

    Path.wildcard(Path.join([toolkit_dir, "skills", "*.md"]))
    |> Enum.reject(fn p -> MapSet.member?(skip, Path.basename(p)) end)
    |> Enum.map(fn p ->
      {slug, work, meta} = p |> File.read!() |> to_work(toolkit)
      out = Path.join(out_dir, Path.basename(p, ".md") <> ".work")
      File.write!(out, work)
      {slug, out, meta}
    end)
  end

  # ── parsing ──────────────────────────────────────────────────────────────

  defp take_title([h | t]) do
    case Regex.run(~r/^#\s+(.*\S)\s*$/, h) do
      [_, title] -> {title, t}
      _ -> {String.trim(h), t}
    end
  end

  defp take_title([]), do: {"untitled", []}

  # Consume the optional "# When to use this" header + NETWORK:/DESTRUCTIVE: lines anywhere near the top.
  defp take_flags(lines) do
    {net, lines} = pull_flag(lines, ~r/^NETWORK:\s*(yes|no)/i)
    {des, lines} = pull_flag(lines, ~r/^DESTRUCTIVE:\s*(yes|no)/i)
    lines = Enum.reject(lines, &Regex.match?(~r/^#\s+When to use this\s*$/i, &1))
    {net, des, lines}
  end

  defp pull_flag(lines, re) do
    case Enum.find(lines, &Regex.match?(re, &1)) do
      nil -> {false, lines}
      hit -> {Regex.run(re, hit) |> List.last() |> String.downcase() == "yes", List.delete(lines, hit)}
    end
  end

  # The intro is the run of prose up to the first section header (`#`/`##`).
  defp take_intro(lines) do
    {intro, rest} = Enum.split_while(lines, fn l -> not Regex.match?(~r/^\#{1,6}\s/, l) end)
    {intro |> dedent() |> unwrap_prose() |> String.trim(), rest}
  end

  # Toolkit `.md` hard-wraps prose at ~50 cols with a 2-space indent. Strip the common leading indent
  # from non-code lines (cleaner chunk text → better embeddings), leaving fenced code verbatim.
  defp dedent(lines) when is_list(lines), do: lines |> Enum.join("\n") |> dedent()

  defp dedent(s) when is_binary(s) do
    s
    |> String.split("\n")
    |> map_outside_fences(fn line -> Regex.replace(~r/^\s{1,4}(?=\S)/, line, "") end)
    |> Enum.join("\n")
  end

  # Join hard-wrapped prose lines back into paragraphs: a non-blank, non-list, non-heading line that
  # follows another such line is a soft-wrap continuation. Leaves blank-line-separated paragraphs and
  # list items intact, and never touches fenced code.
  defp unwrap_prose(s) do
    s
    |> String.split("\n")
    |> reflow_outside_fences()
    |> Enum.join("\n")
  end

  defp map_outside_fences(lines, fun) do
    {out, _} =
      Enum.map_reduce(lines, false, fn line, in_fence? ->
        cond do
          Regex.match?(~r/^\s*```/, line) -> {line, not in_fence?}
          in_fence? -> {line, in_fence?}
          true -> {fun.(line), in_fence?}
        end
      end)

    out
  end

  defp reflow_outside_fences(lines) do
    {acc, _fence, _prev} =
      Enum.reduce(lines, {[], false, :start}, fn line, {acc, in_fence?, prev} ->
        fence_toggle? = Regex.match?(~r/^\s*```/, line)

        cond do
          fence_toggle? -> {[line | acc], not in_fence?, :other}
          in_fence? -> {[line | acc], in_fence?, :other}
          cont?(line, prev) -> [h | t] = acc; {[h <> " " <> String.trim(line) | t], in_fence?, :prose}
          true -> {[line | acc], in_fence?, line_kind(line)}
        end
      end)

    Enum.reverse(acc)
  end

  defp cont?(line, :prose), do: line_kind(line) == :prose
  defp cont?(_line, _prev), do: false

  defp line_kind(line) do
    cond do
      String.trim(line) == "" -> :blank
      Regex.match?(~r/^\s*([-*]|\d+\.)\s/, line) -> :list
      Regex.match?(~r/^\#{1,6}\s/, line) -> :heading
      true -> :prose
    end
  end

  # ── rendering ────────────────────────────────────────────────────────────

  # Normalize headings so every section is a `## ` chunk leaf: level-1 → `## `, deeper `## N.` → `### `.
  # Demote the original "title" level only (level-1 non-title already past). Rewrite md links → backlinks.
  defp render_body(lines) do
    lines
    |> dedent()
    |> String.split("\n")
    |> Enum.map(&normalize_heading/1)
    |> reflow_outside_fences()
    |> Enum.join("\n")
    |> rewrite_links()
    |> String.trim()
  end

  defp normalize_heading(line) do
    cond do
      Regex.match?(~r/^#\s+/, line) -> Regex.replace(~r/^#\s+/, line, "## ")
      Regex.match?(~r/^##\s+/, line) -> Regex.replace(~r/^##\s+/, line, "### ")
      Regex.match?(~r/^###\s+/, line) -> Regex.replace(~r/^###\s+/, line, "#### ")
      true -> line
    end
  end

  # `[text](slug.md)` and `[text](slug.md) — note` → `[[slug]] — note` (the free Edge graph for S5).
  defp rewrite_links(s) do
    Regex.replace(~r/\[([^\]]+)\]\(([^)]+?)\.md\)/, s, fn _, _text, target ->
      "[[#{Path.basename(target)}]]"
    end)
  end

  # ── metadata ─────────────────────────────────────────────────────────────

  defp slug_for(toolkit, title) do
    name =
      title
      |> strip_toolkit_prefix(toolkit)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    "#{atomize(toolkit)}__#{name}"
  end

  defp atomize(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

  defp strip_toolkit_prefix(title, toolkit) do
    title
    |> String.replace(~r/^#{Regex.escape(toolkit)}\s*[—–-]\s*/i, "")
    |> String.trim()
  end

  defp description(intro, base, network, destructive) do
    first =
      intro
      |> String.split(~r/(?<=[.!?])\s+/, parts: 2)
      |> List.first()
      |> Kernel.||("")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    lead = if first == "", do: base, else: first
    flags = [network && "NETWORK", destructive && "DESTRUCTIVE"] |> Enum.filter(& &1) |> Enum.join(". ")
    [lead, flags] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ") |> truncate(280)
  end

  defp intro_or_default("", base), do: "#{base}."
  defp intro_or_default(intro, _base), do: intro

  # ── string utils ─────────────────────────────────────────────────────────

  defp wrap(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
  end

  defp escape(s), do: s |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))
  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: (String.slice(s, 0, n - 1) |> String.trim_trailing()) <> "…"
  defp squeeze_blanks(s), do: Regex.replace(~r/\n{3,}/, s, "\n\n")
end
