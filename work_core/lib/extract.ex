defmodule WorkCore.Extract do
  @moduledoc """
  §0.2 — one entry point over a `WorkCore.Literate` `:code` node: route it to the
  right per-language extractor and return the unified `%{exports, imports, types,
  calls}` shape. Elixir blocks (carrying an `:ast`) use the real Elixir AST;
  everything else uses the foreign pattern extractor (interim until tree-sitter).
  """

  @spec facts(map) :: map
  def facts(%{ast: ast} = node) when not is_nil(ast),
    do: WorkCore.Extract.Elixir.extract(node)

  def facts(node), do: WorkCore.Extract.Foreign.extract(node)
end
