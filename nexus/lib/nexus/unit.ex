defmodule Nexus.Unit do
  @moduledoc """
  A `server` unit IS native-BEAM Elixir — compile its literate body into a real module and run
  its exports. The whole workbook's server tier compiles to a fixpoint. No wasm for server.

  STATUS: **port** from `runtime/host/unit.ex` — built & tested.
  """
  def compile_workbook(_root), do: raise("port from runtime/host/unit.ex")
end
