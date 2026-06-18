defmodule WorkCore.Extract do
  @moduledoc """
  §0.2 — one entry point over a `WorkCore.Literate` `:code` node: route it to the
  right per-language extractor and return the unified `%{exports, imports, types,
  calls}` shape. Elixir blocks (carrying an `:ast`) use the real Elixir AST;
  everything else uses the foreign pattern extractor (interim until tree-sitter).
  """

  @spec facts(map) :: map
  # Memo-aware: a node annotated once (see annotate/1) carries its facts, so the
  # graph (§9) and the WIT feed (§2) — which both read the same nodes, and re-read
  # them several times each — extract per node exactly once instead of per call.
  def facts(%{facts: facts}) when is_map(facts), do: facts

  def facts(%{ast: ast} = node) when not is_nil(ast),
    do: WorkCore.Extract.Elixir.extract(node)

  def facts(node), do: WorkCore.Extract.Foreign.extract(node)

  @doc """
  Attach facts to a `:code` node (or every code node in a list) so downstream
  layers share one extraction pass. Idempotent; non-code nodes pass through.
  """
  def annotate(nodes) when is_list(nodes), do: Enum.map(nodes, &annotate/1)
  def annotate(%{facts: facts} = node) when is_map(facts), do: node
  def annotate(%{type: :code} = node), do: Map.put(node, :facts, facts(node))
  def annotate(node), do: node
end
