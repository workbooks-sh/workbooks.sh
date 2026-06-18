defmodule Workbooks.Extract.Foreign do
  @moduledoc """
  §0.2 (interim) — exports/imports from a FOREIGN-language code body via
  language-aware patterns, until tree-sitter grammars are provisioned in-sandbox.
  Returns the same `%{exports, imports, types, calls}` shape as `Extract.Elixir`,
  so `Workbooks.Graph` (§9) merges it language-agnostically.

  This is honestly a stopgap: it reads `pub fn` / `export fn` / `def` / `export
  function` and the import seams (`extern "C"`, `wasm_import_module`, `work://`
  imports). When the real per-language ASTs land, only this module changes.
  """

  def extract(%{lang: lang, body: body}) when is_binary(body), do: dispatch(lang, body)
  def extract(_), do: empty()

  defp empty, do: %{exports: [], imports: [], types: [], calls: []}

  defp dispatch("rust", body), do: rust(body)
  defp dispatch("zig", body), do: zig(body)
  defp dispatch("python", body), do: python(body)
  defp dispatch(lang, body) when lang in ["svelte", "solid", "js", "ts"], do: web(body)
  defp dispatch(_lang, _body), do: empty()

  # Rust: `pub fn name(` are exports; `extern "C" { fn name }` and a
  # `wasm_import_module = "x"` link are imports.
  defp rust(body) do
    %{
      exports: named(body, ~r/\bpub\s+fn\s+([a-z_]\w*)/),
      imports:
        named(body, ~r/\bextern\s+"C"\s*\{[^}]*?\bfn\s+([a-z_]\w*)/s) ++
          named(body, ~r/wasm_import_module\s*=\s*"([^"]+)"/),
      types: [],
      calls: []
    }
  end

  # Zig: `export fn name(` are exports.
  defp zig(body), do: %{empty() | exports: named(body, ~r/\bexport\s+fn\s+([a-z_]\w*)/)}

  # Python: top-level `def name(` are exports.
  defp python(body), do: %{empty() | exports: named(body, ~r/^\s*def\s+([a-z_]\w*)/m)}

  # Svelte/Solid/JS: `export function Name` / `export let name` are exports;
  # `from "work://unit"` imports name other units.
  defp web(body) do
    %{
      exports:
        named(body, ~r/\bexport\s+function\s+([A-Za-z_]\w*)/) ++
          named(body, ~r/\bexport\s+let\s+([A-Za-z_]\w*)/),
      imports: named(body, ~r/from\s+"work:\/\/([^"]+)"/),
      types: [],
      calls: []
    }
  end

  defp named(body, re) do
    re |> Regex.scan(body) |> Enum.map(fn [_, m] -> m end) |> Enum.uniq()
  end
end
