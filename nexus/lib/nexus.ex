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
      # compile: .work rust + C units → typed components, automatic + tested (rust via mrustc
      # w/ crates + host imports; C via clang reactor — cleaner, no command machinery). zig
      # pending (its compiler runs through the old command registry, needs the direct-wasmtime
      # treatment first).
      compile: :live,
      # weave: workbook folder → one styled .html — inline markdown (bold/italic/code/links),
      # lists, labeled unit blocks, a clean shell
      weave: :live,
      # dock host-IMPORTS (a component CALLING a host capability). Scalar caps turnkey (a unit
      # imports `now`, gets real unix time). STRING caps PROVEN (the real prize): a C reactor
      # importing emit(ptr,len) against WIT `func(msg: string)` lifts the string — host got
      # "hello from C". The blocker was the rust COMMAND shape (libstd/WASI), not the ABI; the
      # clean reactor lifts cleanly. Remaining = wiring grant→Dock-cap-WIT (see docs/STRING-CAP-ABI.md).
      dock_imports: :string_proven
    }
  end
end
