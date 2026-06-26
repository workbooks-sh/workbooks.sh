defmodule Nexus.Migrate do
  @moduledoc """
  **Import an existing repo** — the wrap-vs-rewrite path + language compatibility matrix (wb-d8ac.15).

  We show a beautiful greenfield demo but adoption lives or dies on import friction: a team with a
  real Node or Go service needs to know "can I bring this as-is, and if not, what's the lift?" This
  analyzer scans a repository, detects its languages (by source extension + manifest files), and maps
  each onto the compile-to-WASM support matrix — so the answer is a concrete recommendation, not a
  sales promise.

  Strategy per language:

    * `:wrap`   — full WASM-native compiler support; bring the code as-is, it runs in the sandbox.
    * `:assist` — partial support; most code ports with some adjustment (the unsupported slice is
      flagged at weave/check time).
    * `:rewrite`— no in-sandbox compiler; the logic must be re-expressed (often thin glue around a
      `:wrap` language, or a `.work` server unit).

  The matrix tracks `nexus/compilers/` reality; update it there and here together.
  """

  # language → {support, strategy, note}. Keep aligned with nexus/compilers/.
  @matrix %{
    "javascript" => {:full, :wrap, "runs in the JS-in-WASM lane (porffor/quickjs)"},
    "typescript" => {:full, :wrap, "compiled via the JS lane"},
    "c" => {:full, :wrap, "clang → wasm"},
    "zig" => {:full, :wrap, "zig self-hosts to wasm"},
    "lua" => {:full, :wrap, "lua compiled to wasm"},
    "rust" => {:partial, :assist, "mrustc + libstd; some crates need adjustment"},
    "go" => {:partial, :assist, "yaegi interpreter; cgo/unsupported stdlib flagged"},
    "swift" => {:partial, :assist, "partial stdlib coverage"},
    "python" => {:none, :rewrite, "no in-sandbox compiler — port hot paths or wrap a JS/C lane"},
    "ruby" => {:none, :rewrite, "no in-sandbox compiler"},
    "java" => {:none, :rewrite, "no in-sandbox compiler"}
  }

  # source extension → language
  @ext %{
    ".js" => "javascript", ".mjs" => "javascript", ".cjs" => "javascript", ".jsx" => "javascript",
    ".ts" => "typescript", ".tsx" => "typescript",
    ".c" => "c", ".h" => "c",
    ".zig" => "zig", ".lua" => "lua", ".rs" => "rust", ".go" => "go", ".swift" => "swift",
    ".py" => "python", ".rb" => "ruby", ".java" => "java"
  }

  # manifest filename → language (a strong signal even with few source files)
  @manifest %{
    "package.json" => "javascript", "tsconfig.json" => "typescript", "cargo.toml" => "rust",
    "go.mod" => "go", "package.swift" => "swift", "requirements.txt" => "python",
    "pyproject.toml" => "python", "gemfile" => "ruby", "pom.xml" => "java"
  }

  @doc "The compatibility matrix entry for a language: `%{support, strategy, note}` (`:rewrite`/`:none` default)."
  @spec compatibility(String.t()) :: map
  def compatibility(lang) do
    {support, strategy, note} = Map.get(@matrix, lang, {:none, :rewrite, "unrecognized language"})
    %{language: lang, support: support, strategy: strategy, note: note}
  end

  @doc """
  Analyze a repository `root`. Returns `%{languages:, files_by_language:, matrix:, recommendation:}`,
  where `recommendation` is the overall move: `:wrap` (everything is fully supported), `:assist`
  (some partial), or `:rewrite` (a dominant unsupported language). Pure filesystem scan; no execution.
  """
  @spec analyze(String.t()) :: map
  def analyze(root) when is_binary(root) do
    files = scan(root)
    counts = language_counts(files)
    langs = counts |> Map.keys() |> Enum.sort()
    matrix = Map.new(langs, &{&1, compatibility(&1)})

    %{
      languages: langs,
      files_by_language: counts,
      matrix: matrix,
      recommendation: recommend(counts, matrix)
    }
  end

  # ── internals ────────────────────────────────────────────────────────────────────────────────────

  defp scan(root) do
    Path.wildcard(Path.join(root, "**/*"))
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(&ignored?/1)
  end

  defp ignored?(path) do
    String.contains?(path, "/node_modules/") or String.contains?(path, "/.git/") or
      String.contains?(path, "/target/") or String.contains?(path, "/_build/")
  end

  defp language_counts(files) do
    Enum.reduce(files, %{}, fn path, acc ->
      base = path |> Path.basename() |> String.downcase()
      ext = path |> Path.extname() |> String.downcase()

      case Map.get(@manifest, base) || Map.get(@ext, ext) do
        nil -> acc
        lang -> Map.update(acc, lang, 1, &(&1 + 1))
      end
    end)
  end

  # Overall recommendation = the most demanding strategy any present language requires, weighted by
  # presence. If the codebase is DOMINATED (>50% of detected files) by a :rewrite language, that's the
  # headline; otherwise the worst strategy among present languages.
  defp recommend(counts, matrix) do
    total = counts |> Map.values() |> Enum.sum()

    cond do
      total == 0 ->
        :wrap

      dominant_rewrite?(counts, matrix, total) ->
        :rewrite

      Enum.any?(matrix, fn {_l, m} -> m.strategy == :assist end) ->
        :assist

      Enum.any?(matrix, fn {_l, m} -> m.strategy == :rewrite end) ->
        :rewrite

      true ->
        :wrap
    end
  end

  defp dominant_rewrite?(counts, matrix, total) do
    rewrite_files =
      counts
      |> Enum.filter(fn {lang, _n} -> matrix[lang].strategy == :rewrite end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    rewrite_files * 2 > total
  end
end
