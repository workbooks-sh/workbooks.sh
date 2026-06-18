defmodule Nexus.Compile do
  @moduledoc """
  Orchestrate one unit → its artifact, by kind:
    resource        → an Ash resource (the database)
    server          → a native BEAM module (Nexus.Unit)
    client/foreign  → a wasm component (the compilers → wasm), run on Nexus.Sandbox
  The compilers (source → wasm) are REUSED from `runtime/host/compilers/*` — the moat, not rewritten.

  STATUS: **new** — the orchestrator. Reuses the compilers; routes by placement.
  """
  def unit(_node), do: raise("not built — route by kind; reuse runtime compilers for wasm")
end
