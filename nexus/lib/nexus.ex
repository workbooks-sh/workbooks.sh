defmodule Nexus do
  @moduledoc """
  The runtime, rebuilt clean around the literate `.work` authoring model. See `README.md`.

  The whole pipeline, end to end:

      .work file
        │  Nexus.Literate.parse/1        → ordered nodes (md prose + Elixir AST)
        │  Nexus.Resource / Nexus.Wit    → shape + the WIT contract
        ▼
      Nexus.Compile.unit/1               → one unit becomes:
        ├─ a resource?  → a typed struct (persisted via the Nexus.Store seam)
        ├─ a server?    → a native BEAM module        (Nexus.Unit)
        └─ client/foreign? → a wasm component on wasmex (Nexus.Sandbox)
        ▼
      Nexus.Weave.weave/1                → a workbook (folder) → one .html

  Built fresh, green per layer. Authoring + contract are pure Elixir (no deps); data is a typed
  struct + the pluggable `Nexus.Store` seam; the sandbox is wasmex; the compilers are reused from
  `compilers/*` (the moat).
  """

  @doc "The status of each layer — the honest state."
  def layers do
    %{
      literate: :live,
      resource: :live,
      wit: :live,
      dock: :live,
      unit: :live,
      # data: a resource → a typed struct (the zero-dep base, client+server) + Nexus.Store, a
      # pluggable persistence seam. Two live backends: ETS (default, in-memory) + Sqlite (durable,
      # via exqlite). Neon Postgres (cloud) / wasm-SQL slot in behind the same 4 callbacks; Ash later.
      data: :live,
      # audit: a unit may only call host caps it grants (grant: [emit]); Nexus.Audit reports the
      # ungranted ones per unit / per workbook — an ungranted cap is a hard error, not silent reach
      audit: :live,
      # sandbox: real wasm components run on wasmex
      sandbox: :live,
      # compile: .work rust + C + zig units → typed components, automatic + tested. rust via
      # mrustc (crates + host imports); C via clang reactor; zig via zig1 direct (zig→C→reactor,
      # reusing the C lane w/ the zig lib on the include path). All run zig1/clang/mrustc DIRECTLY
      # — no command registry.
      compile: :live,
      # weave: render-aware — a workbook (HTML file, renders client-side) with markdown prose,
      # `show Resource` → live XSS-safe data tables, `show Unit` → baked render() output across all
      # lanes, index composition + nav, and the client `nexus.data` API (baked JSON islands +
      # server fallback). Nexus.Server SSRs it live + serves /data. Data backends: baked / SQLite /
      # server, one API. (Local-only is core — the woven file carries its own data, no runtime.)
      weave: :live,
      # dock host-IMPORTS (a component CALLING a host capability) — TURNKEY for scalar + string
      # PARAMS and string RETURNS, in C and rust. A unit declares `extern { fn emit(...) }` + calls
      # it; Compile types the WIT import from the Dock's signature, the Dock supplies the impl,
      # Sandbox wires it. String-return caps (e.g. the in-memory kv `load(key)->val`) work via the
      # canonical-ABI return area + an injected bump-allocator `cabi_realloc`. Caps: now/emit/store/
      # load/fetch (net — real HTTP GET; TODO: SSRF-safe broker before prod)/complete (llm — real
      # OpenRouter call). Proven full-stack: a wasm unit called the model → "Pong!". Every cap shape
      # has a real impl. (Cap names single-word + collision-free — `log` collided with libm.)
      dock_imports: :live
    }
  end
end
