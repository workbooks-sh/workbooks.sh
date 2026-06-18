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

  @doc "The status of each layer — the honest state."
  def layers do
    %{
      literate: :live,
      resource: :live,
      wit: :live,
      dock: :live,
      unit: :live,
      # data: a resource → live Ash resource with real CRUD (Resource.Ash.materialize)
      data: :live,
      # sandbox: real wasm components run on wasmex
      sandbox: :live,
      # compile: a .work rust unit → typed component, automatic + tested
      compile: :live,
      # weave: workbook folder → one .html (first pass; rich render pending)
      weave: :basic,
      # dock host-IMPORTS (a component CALLING a host capability) — PROVEN: a Rust component
      # imports `add`, the host (Dock, Elixir) provides it, the component calls it → 42. mrustc
      # emits the import as `env::add`; rewriting the core's import module env→$root (wat round-
      # trip) makes the component model map it, then wasmex supplies the impl. Auto-wiring the
      # grant→import→impl path into Nexus.Compile is the next integration.
      dock_imports: :proven
    }
  end
end
