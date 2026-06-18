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
      # dock host-IMPORTS (a component CALLING a host capability) — TURNKEY for scalar caps: a
      # unit's `extern "C"` decl → WIT import (auto) → env→$root rewrite → componentize → the
      # Dock supplies the impl, Sandbox wires it. Proven: a unit imports `now`, calls it, gets
      # real unix time, zero manual steps. String-typed caps (net/kv/llm) await the canonical-ABI
      # string glue between an extern "C" decl and a WIT `string` — the next nut.
      dock_imports: :live_scalar
    }
  end
end
