defmodule Nexus.Compile do
  @moduledoc """
  Route a parsed unit to its artifact — the one place placement becomes execution:

      resource         → an Ash resource          (the database; `Nexus.Resource.Ash`)
      record           → a value shape             (`Nexus.Resource`)
      server           → a native BEAM module      (`Nexus.Unit`)
      client / foreign → a wasm component          (the compilers → `Nexus.Sandbox`)

  Server units are native Elixir — no wasm. Everything else that isn't pure data compiles to
  wasm via OUR compilers (the moat) and runs on wasmex. The compilers are *reused* from the
  existing toolchain when we wire them in; this module just routes and orchestrates.
  """

  @wasm_kinds ~w(client sandbox rust zig c cpp python svelte solid js ts)

  @doc "Compile one parsed `:code` unit to its artifact, tagged by lane."
  def unit(%{type: :code, kind: kind} = node) do
    cond do
      kind == "resource" -> {:ash, Nexus.Resource.Ash.source(node)}
      kind == "record" -> {:shape, Nexus.Resource.fields(node)}
      kind == "server" -> {:beam, Nexus.Unit.compile(node)}
      kind in @wasm_kinds -> {:wasm, {:compilers, node.lang, node.name}}
      true -> {:skip, kind}
    end
  end

  def unit(_), do: {:skip, :not_a_unit}

  @doc """
  Compile a whole workbook's BEAM tier now (the non-wasm half is fully real). Returns
  `%{compiled, failed}` — the live `server`/type modules. The wasm tier joins when the
  compilers are wired through `unit/1`'s `:wasm` lane.
  """
  def workbook(root), do: Nexus.Unit.compile_workbook(root)
end
