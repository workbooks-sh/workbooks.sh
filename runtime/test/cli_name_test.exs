defmodule CliNameTest do
  @moduledoc """
  GUARDRAIL: the CLI is named `work`. This test fails if ANY stale CLI name (`wb`
  or `wbx`, as a command invocation) survives anywhere in the tree — so a rename
  can never again be "mostly done". It is the enforcement mechanism, not a vibe:
  green here == the rename is complete; red lists every offender with file:line.

  It targets COMMAND INVOCATIONS only — `wb <verb>`, `wbx <verb>`, inline `` `wb ` ``,
  the old escript name, the agent tool name, usage strings. It deliberately does NOT
  match bead IDs (`wb-0lw8`), module/var names, or `workbooks`/`work-*`/`webhook`
  substrings (word-boundaried, hyphen excluded).
  """
  use ExUnit.Case, async: true

  @repo Path.expand("../..", __DIR__)

  # Scan the WHOLE repo — NOT a dir allow-list. A missed directory (desktop/scripts,
  # .github, runtime/scripts) is exactly how a rename ends up "mostly done".
  @exts ~w(.ex .exs .org .md .svelte .ts .js .mjs .cjs .json .toml .sh .txt .html .yml .yaml)
  @skip_names [Path.basename(__ENV__.file)]

  # `wb`/`wbx` followed by ANY command word — NOT a verb allow-list (a missed verb
  # is exactly how a rename ends up "mostly done"). The space requirement keeps bead
  # IDs (`wb-0lw8` — hyphen, no space) and `workbooks`/`webhook` safe. The lookbehind
  # rejects mid-word matches (`newb deploy`).
  @cmd_re ~r/(?<![\w-])wbx?\s+[A-Za-z]/
  # Inline code-fenced bare command: `wb` / `wbx` / `wb ` at a backtick.
  @backtick_re ~r/`wbx?(?:`|\s)/
  @escript_re ~r/\bwb-rt\b/
  @tool_re ~r/name:\s*"wbx?"/
  @usage_re ~r/\busage:\s*wbx?\b/
  # Bare standalone `wbx` anywhere (the in-flight rename's prose). `wbx` is not a bead
  # prefix, so this is safe; bare `wb` is NOT checked (it would hit `wb-…` bead IDs).
  @bare_wbx_re ~r/\bwbx\b/

  @patterns [@cmd_re, @backtick_re, @escript_re, @tool_re, @usage_re, @bare_wbx_re]

  test "no stale `wb`/`wbx` CLI references survive (the CLI is `work`)" do
    offenders =
      walk(@repo)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&(Path.basename(&1) in @skip_names))
      |> Enum.flat_map(&scan_file/1)

    if offenders != [] do
      sample = offenders |> Enum.take(60) |> Enum.map_join("\n", & &1)
      flunk(
        "#{length(offenders)} stale CLI-name reference(s) — the CLI is `work`, not `wb`/`wbx`. " <>
          "Fix every one (this gate is how we keep the rename complete):\n" <> sample
      )
    end
  end

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn e ->
          p = Path.join(dir, e)
          cond do
            e in ~w(_build deps node_modules .git .beads dist .gate) -> []
            File.dir?(p) -> walk(p)
            Path.extname(p) in @exts -> [p]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp scan_file(path) do
    rel = Path.relative_to(path, @repo)

    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      if Enum.any?(@patterns, &Regex.match?(&1, line)),
        do: ["  #{rel}:#{n}: #{String.trim(line) |> String.slice(0, 100)}"],
        else: []
    end)
  end
end
