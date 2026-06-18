defmodule Nexus.Weave do
  @moduledoc """
  A workbook (a folder of `.work` files) → ONE self-contained `.html` (and back). The shipping
  format: parse the tree, compile each unit, bundle into a single hydrate-able page.

  STATUS: **new** — port the bundling idea from `runtime/host/bundle.ex`, thinned to the new model.
  """
  def weave(_root), do: raise("not built — workbook folder → one .html")
end
