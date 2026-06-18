defmodule Nexus.Literate do
  @moduledoc """
  Parse a `.work` file into ordered nodes — `:heading | :code | :decl | :prose`, each with
  `:line` and inline `:refs`; a `:code` node carries `kind/lang/name/header/body/ast`. Markdown
  narrates; `do…end` Elixir blocks run. Combined-AST: Elixir via `Code.string_to_quoted`.

  STATUS: **port** verbatim from `runtime/host/literate.ex` (Workbooks.Literate) — built & tested.
  """
  def parse(_src), do: raise("port from runtime/host/literate.ex")
end
