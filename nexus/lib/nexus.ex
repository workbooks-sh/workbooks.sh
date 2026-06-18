defmodule Nexus do
  @moduledoc """
  The runtime, rebuilt clean around the literate `.work` authoring model. See `README.md`.

  The whole pipeline, end to end:

      .work file
        │  Nexus.Literate.parse/1        → ordered nodes (md prose + Elixir AST)
        │  Nexus.Resource / Nexus.Wit    → shape + the WIT contract
        ▼
      Nexus.Compile.unit/1               → one unit becomes:
        ├─ a resource?  → an Ash resource (the database)
        ├─ a server?    → a native BEAM module        (Nexus.Unit)
        └─ client/foreign? → a wasm component on wasmex (Nexus.Sandbox)
        ▼
      Nexus.Weave.weave/1                → a workbook (folder) → one .html

  Built fresh, green per layer. Authoring + contract are pure Elixir (no deps); data is Ash;
  the sandbox is wasmex; the compilers are reused from `runtime/host/compilers/*` (the moat).
  """

  @doc "The status of each layer — the skeleton's honest state."
  def layers do
    %{
      literate: :port,
      resource: :port,
      wit: :port,
      dock: :port,
      unit: :port,
      sandbox: :new,
      compile: :new,
      weave: :new
    }
  end
end
