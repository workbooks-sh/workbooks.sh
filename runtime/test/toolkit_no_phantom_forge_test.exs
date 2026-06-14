defmodule Workbooks.ToolkitNoPhantomForgeTest do
  @moduledoc """
  Regression guard for the systemic `wb forge` drift (wb-dtd0 / wb-2qy2). The
  canonical Elixir `wb` (runtime/host/cli.ex) has NO `forge` verb — the whole
  `wb forge web|app|desktop|mobile` family was removed with the Rust wb
  (2026-06-09). Six toolkits documented it; an agent reading a phantom command
  in a skill tries it and flails or fabricates output.

  The invariant: no toolkit doc may contain a `wb forge` command in a RUNNABLE
  CODE BLOCK (an org `#+begin_src` block or a markdown ``` fence). Prose mentions
  in a "this was removed, do not invoke it" note are fine and expected — only a
  runnable example is the bug. Deterministic: pure file scan, no network/LLM.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp doc_files do
    Path.wildcard(Path.join(@root, "toolkits/**/*.org")) ++
      Path.wildcard(Path.join(@root, "toolkits/**/*.md")) ++
      Path.wildcard(Path.join(@root, "web/toolkits/content/*.md"))
  end

  # Walk a doc's lines tracking code-fence state; collect `wb forge` hits that
  # land INSIDE a fence. Org uses #+begin_src/#+end_src; markdown uses ``` toggles.
  defp fenced_forge_hits(path) do
    org? = String.ends_with?(path, ".org")

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, n}, {in_fence?, hits} ->
      trimmed = String.trim_leading(line)

      cond do
        org? and String.starts_with?(String.downcase(trimmed), "#+begin_src") -> {true, hits}
        org? and String.starts_with?(String.downcase(trimmed), "#+end_src") -> {false, hits}
        not org? and String.starts_with?(trimmed, "```") -> {not in_fence?, hits}
        in_fence? and String.contains?(line, "wb forge") ->
          {in_fence?, [{Path.relative_to(path, @root), n, String.trim(line)} | hits]}
        true -> {in_fence?, hits}
      end
    end)
    |> elem(1)
  end

  test "no toolkit doc has a `wb forge` command inside a runnable code block" do
    hits = Enum.flat_map(doc_files(), &fenced_forge_hits/1)

    assert hits == [],
           "phantom `wb forge` command(s) in runnable code blocks (the canonical wb has no forge verb — " <>
             "use the real CLI; keep `wb forge` only in prose 'removed' notes):\n" <>
             Enum.map_join(hits, "\n", fn {f, n, l} -> "  #{f}:#{n}  #{l}" end)
  end

  test "the scan actually covers the de-drifted toolkits (guard isn't silently empty)" do
    files = doc_files()
    # If the toolkit tree moved, this guard would pass vacuously — assert it sees real files.
    assert length(files) >= 6
    assert Enum.any?(files, &String.contains?(&1, "capacitor"))
    assert Enum.any?(files, &String.contains?(&1, "wrangler"))
  end
end
