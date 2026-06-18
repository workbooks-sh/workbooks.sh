# WORK-FORMAT IMPLEMENTATION PLAN — aligning the runtime to the spec

Status: planning. Canonical spec (the settled direction this aligns to):

- Authoring = literate `.work` files (markdown + Elixir). NOT web-component / HTML-element authoring / JSON sidecars.
- Code placement = a **target keyword** per block: `client` (browser wasm) · `sandbox` (sandbox wasm) · `server` (BEAM, Elixir-only).
- Vocabulary: **sandbox** = the unit · **container** = the OCI deploy image · **nexus** = the server tier · **work** = the CLI.
- Every unit → a **WIT component**; its **WIT world is generated** (exports = public defs, imports = grants).
- WIT + WASI are the runtime & sandbox standards. Toolkits = WIT packages of helpers. Data = WIT types. Engine = wasmtime. JS = StarlingMonkey.
- Telemetry = OpenTelemetry (emit + Dock capability + data source + cross-edge trace context).

This document is **file-level and sequenced**. Each section labels every change as
**[WIRING]** (composing live machinery that already exists) or **[NEW]** (genuinely new build).
The keystone is §2 (WIT-world generation); §1, §3, §4 depend on it.

Glossary of the real modules this touches:

- `runtime/host/compilers.ex` → delegates to `compilers/{rust,native,js,shared}.ex` (rust/zig/c/js/ts → **core** wasm, stdin/stdout).
- `runtime/host/package_manager.ex` + `package_manager/{build,compose,run,paths}.ex` → tangle/build/run-DAG + Component-Model wrapping.
- `runtime/host/package_manager/compose.ex` → `componentize` (wasm-tools, in-sandbox), `compose`/`plug` (wac, native), `componentize_typed`/`build_engine_js` (jco, native).
- `runtime/host/instance.ex` + `instance/imports.ex` → the typed Dock (`workbooks:engine` world); imports gated by `Policy.caps`.
- `runtime/wit/engine.wit` → the hand-written Dock world (5 imports + `run`).
- `runtime/host/host_broker.ex` → sync JSON-envelope Dock for the StarlingMonkey eval-host (`wb:jseval/broker.host-call`).
- `runtime/host/rust_dock.ex` → `env.*` core-module imports for compiled Rust (RustDock).
- `runtime/host/js_dock.ex` → `env.*` core-module imports for Javy/QuickJS JS commands.
- `runtime/host/tools.ex` → provisions javy / wasm-tools / wac / wasi-adapter / jco.
- `runtime/host/telemetry/wasm_bridge.ex` + `telemetry_bus.ex` + `workflow/telemetry.ex` → `_steps.jsonl` ledger + firehose.

---

## §0. THE PARSE LAYER — one literate parser + per-language ASTs — **THE NEW KEYSTONE**

Everything downstream re-guesses a `.work` file's structure with its own regex: the
viewer's highlighter, the code-graph extractor, the weave gate's ref resolution, and
WIT generation off `do…end` headers. **One parse replaces all of it.** This supersedes
the HTML-`work-*` framing (`workbook.ex` over Floki) for literate `.work` files.

The format's own rule makes it tractable: **`do…end` is the code delimiter**, and a
`.work` file's code *is Elixir*, so we parse with real ASTs — not regex — except where
the input genuinely isn't a grammar (markdown prose).

### §0.1 Literate structure — **DONE** (`runtime/host/literate.ex`, `Workbooks.Literate`)

`parse/1` splits a file into ordered nodes: `:heading | :code | :decl | :prose`, each
with `:line` and inline `:refs` (`[[backlink]]`, `:atom`, `@type`, `#tag`, `work://`).
A `:code` node carries `kind / lang / name / header / body / ast`. Tested + verified
against the real demo tree (`workponents/sales/**`). 6/6 green.

### §0.2 Per-language AST — **[NEW]**, one lane per language

The literate parser hands each code **body** to its language's real parser. Status +
plan, per language:

1. **Elixir — DONE inline.** `Code.string_to_quoted/1` already parses Elixir blocks in
   `code_node/3` (kind/name/lang/nested-lang from the tree). Next: walk that quoted AST
   to extract the **signature** (public `def`s + arities), the **types** it speaks
   (`%Struct{}`, atom-unions, tagged tuples), and the **calls/refs** to other units —
   feeding §2 (WIT) and §9 (graph). No new dep; `Macro.prewalk` over the existing AST.
2. **Rust / Zig / C — via the compilers we already build.** These bodies already
   compile through `compilers/{rust,native}.ex`. Add a **signature pass**: run the
   compiler's front-end far enough to emit the extern/`pub fn` signatures (or parse the
   wasm name section / DWARF the lane already produces). Prefer reading the *generated
   component* with `wasm-tools` (compose.ex) over re-parsing source — the exports/imports
   are the AST we need for the graph.
3. **Python / JS / TS / Svelte / Solid — tree-sitter, in-sandbox.** Provision the
   relevant tree-sitter grammars through `tools.ex` (like javy/wasm-tools), run the
   parser as a wasm command via the CommandRegistry. Extract: exported functions
   (island entry points), imported units (`work://` / `import`), and prop shapes.
4. **Unifying shape.** Every per-language pass returns the SAME small record —
   `%{exports: [...], imports: [...], types: [...], calls: [...]}` — so §9 merges them
   without caring which language produced it. This is the "combined AST" surface.

**Test strategy.** Per language: parse a real demo unit (`compute.work` Elixir,
`rust-zig.work` Rust+Zig, `python.work` Python, `svelte.work`), assert the extracted
exports/imports/types match the source. Golden over the whole `sales/**` tree.

**Ordering / deps.** §0.1 is done. §0.2 Elixir-AST extraction is next and gates §2 + §9.
Foreign-language passes can land incrementally (one language at a time); the graph
degrades gracefully (a unit with no AST pass yet still has its literate refs).

### §0.3 Wire the viewer to the parse — **[NEW, small]**

Replace the book viewer's regex `markCode`/highlighter (`workponents/work-format.js`)
with the parser's node spans, so styling is exact ("prose vs code" comes from the parse,
not a guess). Two routes: (a) a tiny `runtime` endpoint returning `Literate.parse` as the
serving tier, or (b) compile `Workbooks.Literate` to wasm (Popcorn, §5) and call it in the
browser — the dogfood end state. Start with (a); move to (b) when §5 lands.

**Risk.** LOW. §0.1 shipped. The foreign passes are additive and isolated per language.

---

## §1. Componentize EVERY compile lane

**Problem (verified).** Only two paths emit a real WIT component today:
`Compose.componentize/1` (Javy **core** → component via `wasm-tools component new --adapt`)
and `Compose.build_engine_js`/`componentize_typed` (JS via jco). The rust/zig/c lanes
(`compilers/rust.ex:rust_compile_to_wasm`, `compilers/native.ex:zig_compile_to_wasm`/`compile_c`)
stop at **core modules** and the default dataflow (`package_manager.ex:run_component_step` → `run/2`)
pipes them over WASI **stdin/stdout**. The component path exists but is opt-in and demo-only
(`compose.ex` moduledoc: "Used only by the demo / advanced build path … NOT the core stdin/stdout dataflow").

**Approach [mostly WIRING].**

1. Add `Compose.componentize_core/1` generalizing the existing `componentize/1`: any core
   command module (rust/zig/c/javy) → component via the **same** `wasm-tools component new --adapt`
   call already implemented (`compose.ex:53-69`, runs `wasm-tools.wasm` in-sandbox under wasmtime).
   The adapter choice (`wasi_snapshot_preview1.command.wasm`, already provisioned by `tools.ex`)
   is lang-agnostic because all four lanes emit a WASI **command** (`_start`) module — so this is
   wiring, not new machinery.
2. Flip the default: in `package_manager.ex:run_component_step` (line ~125) and the build delegators
   in `build.ex:build`/`build_inline`/`build_dir`, route every successful core-module build through
   `componentize_core/1` and have `run/2` (`package_manager/run.ex:85`) execute the **component**
   (wasmtime component run / via an `Instance`) instead of the core module. Keep the core-module
   fast-path behind a `target: :raw` opt for the in-sandbox toolchain steps that still need a bare
   module (the compiler-internal `clang.wasm`/`zig1.wasm` invocations must NOT be componentized).
3. Make component the **default** artifact extension in `Paths.cache()`; key by `core_path + adapter`
   (already the cache key in `componentize/1`).

**[NEW] only:** a per-lang post-processing step is needed where a lane emits a **reactor**
(library export) rather than a command — today none do, but §2's generated worlds will. Defer the
reactor adapter until §2 lands (the moduledoc in `compose.ex:23-26` already warns the reactor adapter
yields an export-less component; the command adapter is correct for `run`-shaped units).

**Test strategy.** Extend the compilers suite: for each lang, compile a trivial `echo` unit, assert
`validate_component/1` returns `:valid` (already in `compose.ex:207`), then assert
`run_component_step` produces identical stdout to the pre-change core-module path (golden output).
Add one cross-lang DAG test (rust → zig → c) through `run_dag/2` proving componentized stages still pipe.

**Ordering / deps.** Can land **before** §2 for the command shape (stdin/stdout-over-component).
The typed-edge variant waits on §2. Depends on `tools.ex` keeping `wasm-tools.wasm` provisioned (it does).

**Risk.** LOW–MED. `wasm-tools component new` over a non-Javy core module may surface adapter
mismatches (memory export names, missing `cabi_realloc`). Mitigation: the validate-then-golden gate
catches it per-lang; fall back to `target: :raw` for any lane that can't yet componentize, tracked not blocking.

---

## §2. AUTO-GENERATE a per-unit WIT world from signature + grants — **THE KEYSTONE [NEW]**

**Problem (verified).** This does not exist. `runtime/wit/engine.wit` is **hand-written** and fixed
(5 imports + `export run: func(input: string) -> string`). `compose.ex:pipe_wit/1` synthesizes a
**fixed 2-port** `producer`/`consumer` WIT for the typed-compose demo only. There is no mapping from a
unit's declared signature (its public defs) to **exports**, nor from its declared grants to **imports**.
The spec says: *every unit's WIT world is generated; exports = public defs, imports = grants.*

**Approach [NEW — this is the genuinely new build].** A new module
`runtime/host/wit/world_gen.ex` (`Workbooks.Wit.WorldGen`):

1. **Input** = the unit's parsed signature from the tangle plan (`Workbooks.Workbook.tangle_plan` /
   `package_manager/build.ex:build`'s `%{"name","lang","src", target}` map, extended with a `sig` and
   `grants` field — see §2.4). Signature carries: public function names, their param/return **WIT types**.
2. **Type mapping.** Generalize `compose.ex:wit_type/1` (currently `f64|string|bytes|list<u8>`) into a
   full `Workbooks.Wit.Types` covering the spec's data model: `record / variant / enum / flags / list / option / result / tuple` + scalars. Author-declared types in the unit map to a generated `interface types`.
3. **Exports** = one `world <unit>` with `export <fn>: func(<params>) -> <ret>` per public def
   (replacing the single fixed `run`). A unit with no explicit signature defaults to the current
   `run: func(input: string) -> string` (back-compat with §1 command units).
4. **Imports** = one `import` per grant, drawn from a **grant→WIT-import registry** that mirrors the
   live Dock surface: `vfs → vfs-query`, `commands → run-command`, `llm → llm-complete`,
   `browse → browse-fetch`, `parallel → run-command-many`, plus the broader grants RustDock/JsDock
   expose (`net`, `kv`, `secrets`, `queue`, `tcp`, `udp`, `tls`, `encode`). This registry is the
   **single source of truth** that §3's unified Dock and `engine.wit` both consume — see §3.
5. **Code placement (`client`/`sandbox`/`server`).** The target keyword selects the world's WASI
   profile + adapter: `client`/`sandbox` → componentized WIT world (§1) with the WASI subset the
   grants imply; `server` → no wasm world (Elixir-only, runs on the BEAM directly; its "world" is a
   typed Elixir behaviour, not a `.wit`). Emit `client`/`sandbox` worlds; skip wasm for `server`.

   2.4 **Plumb `sig` + `grants` + `target` through the tangle plan.** Edit
   `Workbooks.Workbook.tangle_plan` (Floki/literate parser) and `package_manager/build.ex` so each
   component map carries `target` (the keyword), `sig` (public defs), and `grants` (declared caps).
   Today `build.ex` keys only on `name`/`lang`/`src`/`deps`. **[WIRING]** of the parser; **[NEW]** fields.

6. **Wire generation into the build.** `package_manager/build.ex:build` calls `WorldGen.world(comp)`,
   writes the `.wit` to `Paths.cache()`, and §1's `componentize` step uses **the generated world** as
   the `--wit`/world for the jco lane and as the adapter target for the core lanes. Replace the
   hand-written `engine.wit` reference in `instance.ex`/`imports.ex` with the generated world per unit.

**Test strategy.** Pure-unit tests on `WorldGen.world/1`: signature+grants in → exact WIT text out
(golden `.wit` fixtures). Property test: every grant in `Policy.caps` has a registry entry (fails if a
cap is added without a WIT import — guards drift). Integration: generate a world for a 2-grant unit,
componentize it (§1), instantiate via `Instance` (§3), assert the granted imports resolve and a
non-granted import **fails to instantiate** (the existing "capability by construction" invariant in
`instance.ex:36-59` / `imports.ex:26`).

**Ordering / deps.** **Blocks** the typed half of §1, all of §3, and §4's typed dataflow. Depends only
on the tangle-plan field plumbing (2.4). Land 2.4 → `Wit.Types` → `WorldGen` → wire into build.

**Risk.** HIGH (new, central). Risks: type-mapping gaps for exotic author types (mitigate: fall back
to `list<u8>` bytes as `wit_type/1` already does, with a warning); world-name collisions (namespace by
`workbooks:unit/<name>`); jco/wasm-tools rejecting a generated world (mitigate: `validate_component`
gate + golden `.wit` round-trip through `wasm-tools component wit`).

---

## §3. Collapse the 3+ Dock seam styles into ONE unified Dock

**Problem (verified).** Four parallel host-import surfaces exist, each with its own style and its own
copy of capability gating:

| seam | file | style | gating |
|---|---|---|---|
| Instance WIT-world Dock | `instance/imports.ex` | typed closures keyed by WIT import name (`vfs-query`, `run-command`, `llm-complete`, `browse-fetch`, `run-command-many`) | by **presence**, from `Policy.caps` |
| host_broker (JS eval-host) | `host_broker.ex` | ONE sync import `host-call(jsonReq)->jsonResp`, JSON-envelope op dispatch | grant closed over host-side, default-deny |
| RustDock | `rust_dock.ex` | `env.*` core-module imports (ptr/len ABI) | by presence (`maybe(...)`) from `Policy.caps` |
| JsDock | `js_dock.ex` | `env.*` core-module imports (Javy.Net/VFS), gated by **behavior** (denied → -1) | always-present, behavioral |

This is the same capability set expressed four ways. The spec wants **one Dock**.

**Approach [WIRING + light NEW].** Make the **WIT-world Dock the canonical seam** and reduce the others
to **transports** onto it:

1. **[NEW] `runtime/host/dock.ex` (`Workbooks.Dock`)** — the single capability registry: a map
   `capability_name → %{wit_import, wit_sig, impl_fn, grant_required}`. The existing impls move here
   verbatim from `imports.ex` (`run_command`, `llm_complete`, `browse_fetch`, `run_command_many`,
   `vfs_query`). This is the **same registry §2.4 reads** for grant→import generation — one source of truth.
2. **`imports/ex` becomes a thin projection [WIRING]:** `Instance.Imports.for_caps` already builds the
   WIT-typed closure map — reimplement it as `Dock.wit_imports(caps, ctx)` selecting from the registry.
   Net deletion of the per-cap `add/4` clauses.
3. **host_broker → a transport, not a second Dock [WIRING].** `host_broker.ex`'s `do_op/3` dispatch
   becomes a **JSON-envelope adapter over `Dock`**: each `op` (`exec`/`fs`/`llm`/`creds`/`oauth`) maps to
   a Dock capability call. The sync round-trip transport (`import_fn/1`, the Condvar) stays — it's the
   StarlingMonkey-specific wire, not a capability surface. Grant→Dock-cap translation replaces the
   bespoke `gate/1`. (Note: host_broker's `exec`/`spawn`/`stream`/`creds`/`oauth` ops are a **superset**
   of the Instance Dock — fold these into the registry as additional capabilities, so the unified Dock
   is the union, not the lowest common denominator.)
4. **RustDock / JsDock → core-module ABI projections [WIRING].** `rust_dock.ex:imports/1` and
   `js_dock.ex:env/5` become `Dock.core_imports(caps, abi: :rust | :javy)` — the SAME registry, projected
   through the ptr/len core-module ABI instead of the WIT-typed component ABI. The per-cap `maybe(...)`
   builders (`egress`, `vfs_caps`, `exec_caps`, `kv_caps`, …) move into the registry's `impl_fn`, with the
   ABI shim (memory read/write) as a thin generated wrapper. Gating becomes uniform: **presence** for
   RustDock (omit unresolved imports), and we keep JsDock's behavioral `-1` only where the harness hard-links.

**Net effect:** one registry (`Dock`), three transports (WIT-typed component, JSON-envelope sync, core ptr/len),
each generated from the same capability definitions. §2's generated worlds and this registry are the same surface.

**Test strategy.** Characterization-first: snapshot the current import maps from all four seams, then
assert the unified `Dock`-projected maps are byte-identical (same import names, same arities, same gating
decisions per profile). Then a parametric test: for each capability × each profile × each transport,
granted ⇒ callable, not-granted ⇒ unavailable/denied. Keep the existing `HarnessSessionTest`,
broker e2e, and instance tests green as the regression net.

**Ordering / deps.** Depends on §2's registry concept (build the registry **with** §2.4, share it).
Land `Dock` registry → project Instance imports → fold host_broker → fold RustDock/JsDock, one seam per PR,
each behind the characterization snapshot.

**Risk.** MED–HIGH. This touches the **security spine** (host_broker's grant model, default-deny,
workdir-confine, no-native-exec). The characterization snapshots + the existing security suites are the
guard; do NOT loosen any gate while unifying. Highest-risk fold is host_broker (it carries exec/creds/oauth).

---

## §4. Integrate the compiler system fully into the default dataflow

**Problem (verified).** The compiler/Component-Model machinery is gated to the **demo/advanced** path:
`compose.ex` moduledoc says componentize/compose/typed are "Used only by the demo / advanced build path
(host/demos/build.ex), NOT the core stdin/stdout dataflow." `package_manager.ex:run_dag`/`run_world`
pipe **core-module stdin/stdout**, and `run_component_step` builds a bare module. So in the default lane,
a unit never becomes a component, never gets a generated world, never docks typed.

**Approach [WIRING].** Make the §1+§2+§3 path the **default** `run_dag` path:

1. `package_manager.ex:run_component_step` (line ~125): `build(comp)` → `WorldGen.world(comp)` (§2) →
   `componentize_core/1` against that world (§1) → execute via an `Instance` (§3 Dock), not `run/2` raw.
2. **Typed edges become the default join.** `compose.ex:typed_compose/1` and `run_world`'s wave-piping
   converge: when an `out → in` edge carries a declared WIT type (from §2), fold the edge with `wac plug`
   (the existing `plug/2` in `compose.ex:198`) instead of string-piping stdout→stdin. When the edge is
   untyped, fall back to the stdin/stdout pipe (back-compat). This promotes the demo-only `typed_compose`
   to the general DAG folder.
3. Retire `host/demos/build.ex` as a **separate** lane — its capabilities are now the default. Keep a
   thin demo example, delete the parallel build path (Golden Rule 5: delete-and-combine).

**Test strategy.** Promote the existing demo build assertions into the default `run_dag` suite. Add a
DAG with one typed edge + one untyped edge, assert the typed edge is `wac plug`-folded (single composed
component, only WASI imports remain — the invariant `compose.ex:127` already documents) and the untyped
edge still pipes. Performance gate: componentizing every step must not regress build time beyond the
content-addressed cache (already keyed; assert cache hits on rebuild).

**Ordering / deps.** **Last** of the build-path sections — depends on §1 (componentize all lanes),
§2 (worlds), §3 (Dock to run components). Pure wiring once those land.

**Risk.** MED. Mostly performance (componentize per step) and the typed-vs-untyped edge branching.
Mitigated by the cache and the untyped fallback. No new security surface.

---

## §5. Popcorn / AtomVM as the Elixir-in-wasm runtime for client (browser only)

**Decision (corrected).** `server` Elixir runs **natively on the BEAM** — real OTP, NOT Popcorn/wasm.
Popcorn is **client-only**: the browser has no BEAM, so a `client` Elixir block needs an Elixir-in-wasm
runtime. Do NOT route `server` through Popcorn. Server isolation / multi-tenancy is the **nexus's** job
(BEAM tenant isolation + capability policy via the Dock + managed egress), not wasm-boxing — that's its
own open security-model task, tracked separately.

**Problem (verified).** The `client` placement lets blocks be authored in Elixir (literate `.work` =
markdown + Elixir), and there is **no Elixir→wasm lane** in `compilers/`. `mix.exs` has no
`popcorn`/`atomvm`/`orb` dep (verified: only `wasmex`). The memory canon: **Popcorn/AtomVM is the
Elixir-in-wasm runtime; Orb is a low-level escape hatch, NOT the primary path.**

**Approach [NEW].** New lane `runtime/host/compilers/elixir.ex` (`Workbooks.Compilers.Elixir`) +
`Workbooks.Compilers.elixir_compile_to_wasm/3` delegated from `compilers.ex` (mirroring
`rust_compile_to_wasm`/`js_compile_to_wasm` delegation at `compilers.ex:68-77`):

1. Vendor **Popcorn** (AtomVM-on-wasm packager). The lane compiles the Elixir block → BEAM `.beam` →
   packs into the AtomVM wasm runtime image Popcorn produces. Provision the AtomVM wasm + Popcorn packer
   through `tools.ex` (`@required` list, `ensure!`) the same way javy/wasm-tools are provisioned.
2. The packed artifact is a **core module / WASI command**; feed it through §1's `componentize_core` so
   an Elixir `client` unit gets a generated WIT world (§2) and docks like any other lane.
3. **Placement routing (§2.4 `place`):** `place: server` → native BEAM (no wasm); `place: client` →
   Popcorn/AtomVM lane → component. Foreign-language units (anywhere) compile to wasm regardless.
4. **Orb stays an escape hatch:** expose `client, via: :orb` only for the rare hand-tuned numeric kernel;
   not the default, not in the happy path. Do not let Orb become the primary Elixir→wasm route (canon).

**Test strategy.** Smoke: compile `def add(a,b), do: a+b` as a `client` Elixir unit, instantiate, call
through the Dock, assert result. Parity: the SAME Elixir source as `server` (BEAM) vs `client` (AtomVM)
produces identical output. Provisioning test: `tools.ex` self-heals the AtomVM/Popcorn assets.

**Ordering / deps.** Independent of §1–§4 except it **consumes** §1's `componentize_core` and §2's
`WorldGen`. Can be developed in parallel; integrate after §2.

**Risk.** HIGH (new toolchain, AtomVM subset of Elixir/OTP). AtomVM does NOT run full OTP — document the
supported subset; the lane must return an actionable `{:error, {:atomvm_unsupported, feature}}` (mirror
the rust `RustCaps.diagnose` pattern at `rust.ex:69`). Keep `server` as the full-fidelity fallback.

---

## §6. WIT + WASI as the standard runtime / sandbox interfaces

**Problem (verified).** Partially true already: `instance.ex` runs **components** under
`Wasmex.Components` with `WasiP2Options` (WASI Preview 2), and `wit/engine.wit` is a real WIT world.
But RustDock/JsDock units run as **core modules** under `WasiOptions` (Preview 1) with `env.*` imports —
not WIT, not WASI-P2. And the Dock world is hand-authored, not the standard surface. The spec wants WIT +
WASI to be **the** interface for every sandbox/runtime unit.

**Approach [WIRING, convergent].** This section is the **convergence target** of §1–§3, stated as an
invariant rather than separate new code:

1. After §1, every unit is a **component** → runs under `Wasmex.Components` + `WasiP2Options`
   (`instance.ex:69-80` is already the right shape). The core-module + `WasiOptions` paths
   (`js_dock.ex:43`, RustDock core runs) become **legacy**, kept only for the in-sandbox compiler-internal
   tools (`clang.wasm`, `zig1.wasm`, `mrustc.wasm`) that are infrastructure, not user units.
2. After §3, the `env.*` ptr/len ABI is a **projection** of the WIT Dock, so even where a core module is
   used, its imports are derived from the WIT capability registry — WIT is the source of truth, the core
   ABI is a generated shim.
3. **Standard WASI subset per grant:** the generated world (§2) declares only the `wasi:*` interfaces its
   grants need (the `allow_http`/`net_allow` derivation in `instance.ex:59-66` is the existing model;
   generalize it from "http only" to "the grant set"). Document the canonical world in `runtime/wit/`:
   replace the fixed `engine.wit` with a **template** + the generated per-unit worlds.

**Test strategy.** Invariant test over the build: assert every default-lane unit artifact passes
`wasm-tools validate` as a **component** (not a core module) and instantiates under `WasiP2Options`.
Assert the legacy core path is reachable ONLY for the named compiler-internal tools (allow-list test).

**Ordering / deps.** Emergent from §1+§2+§3; no standalone build. Verify-and-document section.

**Risk.** LOW (it's the convergence checkpoint). Risk is residual core-module paths lingering; the
allow-list invariant test prevents new ones.

---

## §7. Telemetry = OpenTelemetry (emit + Dock capability + data source + cross-edge trace context)

**Problem (verified).** Telemetry today is a **bespoke `_steps.jsonl` ledger**, NOT OpenTelemetry.
`instance/imports.ex:log_step` appends `{step,tool,exit_code,dur_ms,ts}` JSONL; `telemetry/wasm_bridge.ex`
mirrors component-internal spans into the SAME JSONL; `workflow/telemetry.ex` reads it; `telemetry_bus.ex`
fans a runtime firehose. There is **no `opentelemetry` dep** in `mix.exs` (verified), no OTLP export, no
W3C trace-context propagation across the work-component edges. `wasm_bridge.ex:20` even names the
**`wasi:otel` proposal** as the intended future — confirming OTel is the target, not yet wired.

**Approach [NEW emit/export + WIRING of the existing chokepoints].** Four pieces the spec enumerates:

1. **Emit [NEW].** Add `opentelemetry` + `opentelemetry_exporter` (OTLP) deps to `runtime/mix.exs`.
   `instance/imports.ex:log_step` and `telemetry/wasm_bridge.ex` keep writing `_steps.jsonl` (don't break
   the desktop/eval readers) but ALSO open/close a real OTel span per Dock call / per component span. One
   helper `Workbooks.Telemetry.span/3` wraps both writes — single chokepoint, dual sink.
2. **Dock capability [NEW + §3 WIRING].** Add an `otel` capability to the unified Dock registry (§3):
   WIT imports `span-start`/`span-end`/`add-event` (matching the `wasi:otel` shape `wasm_bridge.ex` already
   anticipates). A unit granted `otel` can emit its own spans; the host correlates them into the parent
   trace. This replaces the Dylibso-Observe-SDK transform path with a first-class Dock capability.
3. **Data source [NEW].** Expose collected spans as a queryable **data source** (`runtime/host/data_source*`)
   so a workbook can read its own telemetry — `Workflow.Telemetry.summary/1` (which reads `_steps.jsonl`)
   gains an OTel-backed sibling. Honest status feeds the `/capabilities` dashboard (memory canon).
4. **Cross-edge trace context [NEW].** When §4 folds a DAG edge (typed `wac plug` OR stdin/stdout pipe),
   propagate **W3C `traceparent`** from producer→consumer so one work-graph run is one distributed trace.
   For stdin/stdout edges, inject `traceparent` as an env/header line; for typed component edges, pass it
   through the generated stage interface. This is the genuinely new cross-boundary wiring.

**Test strategy.** Unit: `span/3` writes BOTH a JSONL line (existing readers stay green) AND a finished
OTel span (in-memory exporter assertion). Integration: a 3-stage DAG run yields ONE trace with three
correctly-parented spans (assert shared `trace_id`, parent/child `span_id`s). Back-compat: every existing
`_steps.jsonl` consumer test passes unchanged.

**Ordering / deps.** Emit (7.1) is independent — land first. The Dock capability (7.2) depends on §3.
Cross-edge context (7.4) depends on §4. Data source (7.3) after 7.1.

**Risk.** MED. Risks: OTLP exporter config/perf in the hot Dock path (mitigate: sampling + async export,
never block the guest call); double-write divergence (mitigate: single `span/3` chokepoint). Keeping
`_steps.jsonl` alive is deliberate — the desktop bridge + eval harness read it; do not remove it.

---

## §8. Delivery: SSR from the nexus (static bundle · nexus SSR · live-over-RCP)

**The framing.** One authored workbook, *every* delivery mode — no rewrite. A `.work`
tree compiles once; how it reaches a reader is a deployment choice, not an authoring
one. SSR does **not** eclipse the static bundle; it's the rung you climb when a nexus
is present. The three modes are a ladder, and **every workbook can ride all three**:

| mode | who renders | when | needs a nexus? |
|---|---|---|---|
| **static bundle** | the browser (hydrates the gzip blob) | zero-infra / public / edge | no |
| **nexus SSR** | `server` regions on the BEAM; `client` units = islands | a nexus is declared | yes |
| **live SSR** | stateful server render + diffs over RCP WS | interactive, stateful UI | yes |

The whole ladder falls straight out of the **placement model** (§2, the `target`
keyword / 2.4 plumbing): a unit is `client` or `server`, and that single bit decides
*who renders it*. `server` units render on the trusted BEAM tier; `client` units are
the islands hydrated on top. "Trusted" = allowed-more-caps, **not** sandbox escape —
a `server` region is still wasm-isolated where it runs guest code; it simply runs on a
nexus the author owns and may be granted secrets/db/net (§2.5 grants, §3 Dock).

Glossary of the real modules this touches:

- `runtime/host/bundle.ex` (`Workbooks.Bundle`) → packs/unpacks the portable `.wbundle`
  zip (HTML + VFS + manifest); the decompression-bomb guard mirrored by the JS loader.
- `runtime/host/public_web.ex` (`Workbooks.PublicWeb`) → `static_page/2` / `static_doc/3`:
  the **static** public plane — bytes only, no backend call-home. Serves a complete
  HTML workbook verbatim; wraps a fragment in the doc shell.
- `runtime/host/web.ex` (`Workbooks.Web`, Bandit Plug router, `WB_WEB=1`) +
  `runtime/host/web/pages.ex` (`Workbooks.Web.Pages.workbook_page/2`) → the **authed
  control-plane** page that wires fetch/WS to the nexus (contrast `static_page/2`).
- `runtime/host/instance.ex` + `instance/imports.ex` → the typed Dock that runs a
  `server` unit's compiled component, gated by `Policy.caps` (= where `server` compute
  executes during a render).
- `runtime/host/socket.ex` (`Workbooks.Socket`, `@behaviour WebSock`) → the **live**
  WS bridge: each frame `{"fn", "org"}` → JSON reply, "the interactive upgrade over the
  HTTP backend." This is the RCP transport for live SSR diffs.
- `runtime/host/phoenix_socket.ex` + `web.ex:get "/socket/websocket"` → the multiplexed
  Phoenix-v2 socket already mounted; RCP handshake at `/.well-known/workbooks-runtime`
  (`web/capabilities.ex`).

This is **file-level and sequenced**, same as §1–§7. Each step is **[WIRING]**
(composing live machinery) or **[NEW]**.

### §8.1 Static bundle — already shipped, the floor [WIRING]

This mode exists. `work bundle` (CLI `cli/src/main.rs:Cmd::Bundle` → `local::bundle`)
weaves the tree into one self-contained gzipped `.html` (`wbundle-html/1`): the page +
a compressed blob of wasm/JS/data, hydrated client-side by `web/wb-bundle-loader.js`.
`Workbooks.Bundle.pack/1` is the runtime-side packer; `PublicWeb.static_page/2` serves
the result as inert bytes (CSP: hydrated HTML/JS/wasm stays inert until explicitly
evaluated). **Nothing new here** — it's the baseline every other mode degrades to when
no nexus is declared. The weave already prints `weave ssr (beam) ✓  islands N ✓`
(see `work-format.js:WEAVE`), so the artifact is *already shaped* for SSR; §8.2 makes
that line do real server work instead of pre-rendering everything to the blob.

### §8.2 Nexus SSR — `server` regions render on the BEAM; `client` units are islands [NEW + WIRING]

**Problem.** Today `workbook_page/2` serves a page whose content is rendered up-front
and whose `server` interactions are *fetched after load*. The placement model lets us do
better: a `server` region can be **rendered on the BEAM at request time** and streamed
as HTML, with only the `client` units shipped as hydration islands. That's islands
architecture (Astro-shaped), and the `target` bit already tells us which is which.

**Approach.**

1. **[NEW] `runtime/host/web/ssr.ex` (`Workbooks.Web.SSR`)** — the render orchestrator.
   Input = the woven workbook (the `tangle_plan` units from `Workbooks.Workbook`, each
   now carrying `target` from §2.4). It partitions units by placement:
   - `server` units → **render on the BEAM now**. A `server` Elixir unit runs natively
     (§2.5: `server` is Elixir-on-BEAM, no wasm world); a `server` unit in another lang
     runs its compiled component through an `Instance` (§3 Dock), granted its declared
     caps. The unit's render output (HTML string / element subtree) is spliced into the
     document at its placement marker.
   - `client` units → emit an **island placeholder** (`<div data-wb-island="<name>">`)
     plus the unit's hydration bundle reference. Not rendered server-side; woken in the
     browser exactly as the static blob wakes them.
2. **[WIRING] serve path.** `web.ex:workbook_page` route delegates to `SSR.render/2`
   instead of `Pages.workbook_page/2` for nexus-backed apps (an app that declares a
   `nexus` URL in its index — `c-nx-backs`). The Bandit router streams the assembled
   HTML (`send_chunked` / `send_resp`); the head/shell + island loader come from the
   **same** `static_doc/3` shell `PublicWeb` already emits, so static and SSR pages share
   one shell — no second template (Golden Rule 1).
3. **[WIRING] island hydration.** The client loader (`web/wb-bundle-loader.js`) already
   hydrates islands from the gzip blob. Generalize it: an island's source can come from
   the **inline blob** (static mode) OR a **nexus fetch** (`/api/island/<name>`, SSR
   mode). Same `hydrate(island)` entry; the source URL is the only difference. The
   decompression-bomb caps (`Bundle` + the loader mirror) apply to both.
4. **[WIRING] degradation.** If no `nexus` is declared, `SSR.render/2` is never reached
   — the app builds to a pure static bundle (§8.1). Same source, the deploy target picks
   the path. The compiler's posture gate (`gated_data`/`gated_route`, `c-model-dist`)
   already keeps secrets + gated rows out of whichever artifact ships.

**Test strategy.** Render a 2-unit workbook (one `server` + one `client`): assert the
HTML response contains the `server` unit's rendered output *inline* and a
`data-wb-island` placeholder (not rendered) for the `client` unit. Assert a no-nexus
build of the same source produces a static bundle with both units in the blob. Snapshot
the shared shell from `static_doc/3` across both paths (must be byte-identical head).

**Ordering / deps.** Depends on §2.4 (`target` on every unit) and §3 (Dock to run a
`server` component during render). `server`-Elixir-only render can land before §3;
non-Elixir `server` render waits on §3.

**Risk.** MED. Risks: a `server` render that blocks (DB/net) stalling the stream
(mitigate: render `server` regions with a timeout + an island fallback, same
placeholder the `client` path uses); shell divergence between static and SSR (mitigate:
the single-shell snapshot test).

### §8.3 Live SSR — stateful server render + diffs over RCP WS [NEW + WIRING]

**Problem.** §8.2 is request-shaped: render once, hydrate, done. Interactive apps want a
**stateful** server render where a server-held view pushes **diffs** as state changes —
LiveView-*shaped*. We do **not** adopt Phoenix LiveView wholesale: that would be a second
runtime contract the UI manages, which violates the one-contract canon (CLAUDE.md
architecture canon). Instead we deliver the same capability over **our own RCP WS** — the
nexus is already BEAM, so a stateful per-connection render process is natural.

**Approach.**

1. **[WIRING] transport already exists.** `Workbooks.Socket` is the live bridge — each
   frame `{"fn","org"}` → JSON reply, mounted as "the interactive upgrade over the HTTP
   backend." `web.ex:get "/socket/websocket"` (`PhoenixSocket`) multiplexes topics; RCP
   handshake at `/.well-known/workbooks-runtime` advertises the surface. The socket is
   the wire — **do not add a new one**.
2. **[NEW] `runtime/host/web/live.ex` (`Workbooks.Web.Live`)** — a per-connection live
   view process (a `GenServer` keyed by socket session). It holds the `server` region's
   state, renders it to HTML on mount, and on each state change computes a **minimal diff**
   (a list of `{island_id | region_id, patch}` ops) pushed as an RCP frame. State changes
   come from: a client event frame (`{"fn":"event", ...}`), a `server` unit's own
   emit, or a subscribed data source (`data_source/`) updating. This is the genuinely new
   piece — a stateful render loop, but a small one (render → diff → push).
3. **[WIRING] diff op into the existing socket.** Extend `Socket.dispatch/2` (today
   `parse`/`fn`) with a `mount`/`event` op that routes to a `Web.Live` process and streams
   its diff frames back. The frame envelope stays `{...}` JSON over the same WS — no new
   protocol, just two new ops (one-contract canon honored).
4. **[WIRING] client patch applier.** The island loader (`wb-bundle-loader.js`) gains a
   `applyPatch(frame)` that maps a diff op onto the live DOM (the islands it already
   manages). Same loader, same islands as §8.2 — live SSR is §8.2 + a socket + a patch
   applier, not a separate stack.
5. **[WIRING] escalation, not a fork.** An app opts into live by declaring an
   interactive `server` region; absent that it stays at §8.2 (request SSR) or §8.1
   (static). One source, three rungs — the author never picks a "framework."

**Test strategy.** Mount a live view over a test WS: assert the initial frame is full
HTML; push an event frame; assert the reply is a **diff** (only the changed region's
patch, not a full re-render). Assert an idle connection pushes nothing (the
"connected, quiet" invariant `PhoenixSocket` already documents). Assert no second
socket/route is introduced (route-count snapshot).

**Ordering / deps.** Depends on §8.2 (islands + the shared shell) and §3 (Dock for
`server` compute inside the live loop). Land §8.2 → `Web.Live` process → socket ops →
patch applier.

**Risk.** MED–HIGH. Risks: per-connection process leakage (mitigate: link to the socket,
terminate on close — `Socket.terminate/2` already exists); a diff that desyncs from the
client DOM (mitigate: a full-resync op the client can request; version each region's
state); re-introducing a parallel contract (mitigate: enforce "new ops, not new socket"
in review — the route-count snapshot guards it).

### §8 dependency note

All three modes consume the **placement model (§2.4 `target`)** — that single bit is
what makes "one source, every delivery" true. §8.1 needs nothing new. §8.2 needs §2.4
(+ §3 for non-Elixir `server` render). §8.3 needs §8.2 + §3. None of them re-render the
static bundle's job — they *add* a server tier where a nexus exists and degrade cleanly
to bytes where it doesn't.

---

## §9. The Code Graph — built on the parse, not extracted twice — **[NEW]**

The graph is the join of the three extractors over §0's parse. Now that §0 exists, the
graph is mostly *assembly*, not re-parsing.

1. **`Workbooks.Graph` — nodes + typed edges.** A node per unit (from each `:code` node:
   `id=name, kind, lang, place, sandbox, exports`). Edges, typed: `:ref` (from a node's
   `.refs`), `:import` (from §0.2 calls/grants), `:dataflow` (a `%Struct{}` produced
   here, consumed there), `:type` (unit → struct/enum it speaks), `:tag` (`#tag`).
2. **Three feeds merge.** literate (§0.1 refs) + per-language AST (§0.2 exports/imports/
   calls) + WIT (§2 generated worlds). Disagreement is signal: a prose `:ref` with no
   AST call is a *dangling mention* the gate flags.
3. **The CLI surface.** `work check` (resolve every edge; dangling ref, unused grant,
   capability leak across a sandbox), `work why :x` (rdeps), `work near :x` (the context
   subgraph). These walk `Workbooks.Graph`, build-time and runtime.
4. **Telemetry rides it (§7).** OTel spans map to graph nodes — structure (the parse) +
   behaviour (OTel) on one surface.

**Test strategy.** Over `sales/**`: assert every `[[backlink]]`/`:atom` resolves (matches
the demo's own `work check` expectation), no cross-sandbox `:import` without host-broker,
no dead exported unit. This is the gate that made the demo coherent — now enforced by code.

**Ordering / deps.** Depends on §0.1 (done) + §0.2 (Elixir pass at least) + §2 (WIT feed,
for the import layer). The literate-only graph (refs) can ship first on §0.1 alone.

---

## Dependency graph (sequence)

```
§0.1 literate parser  ✓DONE ──────────► §0.3 viewer-on-parse
        │                                §9 code graph (refs feed) ◄─┐
        ▼                                                            │
§0.2 per-language AST (Elixir → foreign) ───────────────────────────┤
        │                                                            │
        ▼                                                  §9 graph (AST + WIT feeds)
§2.4 tangle-plan fields (sig/grants/target)
        │
        ▼
§2 WorldGen + Wit.Types  ──────────────┐ (KEYSTONE)
        │                              │
        ▼                              ▼
§1 componentize all lanes        §3 unified Dock registry
        │                              │
        └──────────────┬───────────────┘
                       ▼
        §4 default dataflow = componentized + typed edges
                       │
        ┌──────────────┼───────────────┬───────────────┐
        ▼              ▼               ▼               ▼
   §6 WIT+WASI    §5 Popcorn/AtomVM   §7 OpenTelemetry  §8 Delivery / SSR
   (verify)       (parallel)          (emit→edge-ctx)   (8.1 ships · 8.2→8.3)
```

§8 rides §2.4 (`target`) + §3 (Dock for `server` render). 8.1 (static bundle) is live
today; 8.2 (nexus SSR / islands) and 8.3 (live-over-RCP) layer on once §3 lands.

Land order: **§0.1 ✓ → §0.2(Elixir) → §2.4 → §2 → §9(refs graph early, full after §2) → §1 → §3 → §4 → §6 → §7 → §5**.
§0.3 (viewer-on-parse) and §0.2 foreign-language passes land in parallel, incrementally.
§7.1 (emit) and §5 (lane) can start in parallel once §1 exists.

---

## Appendix A — medium/low-confidence DRIFT FIXES (NOT auto-applied; human review)

These are stale-vocabulary / direction-drift items found in the touched files. They contradict the
work-format canon (kill org-mode, OQL, "tangle"/"source" as authoring keywords, QuickJS-as-engine claims,
web-component authoring). Flagged, not changed, because they're load-bearing names with cross-repo callers:

1. **`tangle` / `tangle_plan` is a deprecated authoring keyword.** Used everywhere as the parse entry
   point (`package_manager.ex:tangle`, `Build.tangle`, `compose.ex:135`, `run_dag`). Canon retires
   "tangle"/"source" as authoring verbs. Rename to a neutral term (`Workbook.units/1` / `plan/1`) — but
   it's the literate-parse seam with many callers, so this needs a coordinated rename, not a sweep.
2. **`org` parameter names everywhere.** `typed_compose(org)`, `run_dag(org, input)`,
   `tangle(org)` take a param literally named `org` (org-mode residue). Org-mode is DEPRECATED. Rename
   the params to `unit`/`workbook`. Low risk (local), deferred only to batch with #1.
3. **QuickJS claims in `js_dock.ex` moduledoc** ("compiled-JS (QuickJS) commands", "inside QuickJS-under-
   wasmtime"). Canon: JS engine is **StarlingMonkey**, not QuickJS. `build.ex:128` also says "QuickJS-ng".
   The Javy/QuickJS command lane may be genuinely separate from the StarlingMonkey eval-host — VERIFY which
   engine each path actually uses before rewording (could be a real two-engine situation, not just stale copy).
4. **`compose.ex` references `docs/COMPOSE-NOTES.org`** (an `.org` doc) in 3 places. Org docs are
   deprecated authoring; the doc should be `.md` or folded into this file. Low risk.
5. **`build_dir(dir, "rust")` comment cites `cargo component`** (`build.ex:99`) as the WIT-world path —
   once §2 generates worlds, that comment is stale (we won't use cargo-component for world generation).
   Re-document after §2.
6. **`engine.wit` is hand-authored and fixed** — once §2 lands, this file becomes a template, not the
   surface. Don't delete pre-emptively; §2 supersedes it.

## Appendix B — INVESTIGATE / KEEP cruft (NOT auto-applied; human decision)

Modules/paths that look adjacent or redundant but should NOT be touched blindly:

1. **`host/demos/build.ex`** — §4 proposes retiring it as a separate lane. Confirm nothing outside the
   demo path (evals? CLI verbs? desktop?) calls it before deleting; fold survivors into the default lane.
2. **`acp.ex` / `harness_*` / `host_broker.ex` eval-host** — the StarlingMonkey agent-loop residency
   machinery. §3 folds host_broker's *capability* surface into the unified Dock, but the **sync transport**
   (Condvar round-trip, resident-instance) is load-bearing and must stay. Don't conflate transport with Dock.
2 is the single highest-risk fold — keep the security suites as the gate.
3. **`rust_dock.ex` / `js_dock.ex` as separate modules** — after §3 they're thin ABI projections. Decide
   whether to delete the files (fold into `dock.ex`) or keep as named projections. Either is canon-clean;
   prefer deletion (Golden Rule 5) only once the characterization snapshots are green.
4. **`Compose.compose/1` (structural `wac compose`, non-typed)** — once §4 makes typed `wac plug` the
   default edge fold, the structural-bundle `compose/1` may have no callers. Verify before removing; it
   may still serve multi-export bundling that `plug` doesn't cover.
5. **`telemetry_bus.ex` (the runtime firehose) + `_steps.jsonl`** — KEEP. §7 adds OTel alongside, does NOT
   replace these (desktop bridge + eval harness + `/capabilities` dashboard read them). Removing them would
   break live consumers.
6. **The `wac` / `jco` native-tool carve-out** (`compose.ex:10-13` — they manipulate already-built TRUSTED
   bytes, stay native). This is a deliberate, documented exception to the no-native-exec canon. Do NOT try
   to move them in-sandbox as part of this work; that's a separate tracked effort (needs a WIT-aware JS
   engine in wasm). Leave the carve-out intact.
