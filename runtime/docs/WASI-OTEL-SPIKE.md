
# Question

  Telemetry phase 0b/0c/0e captured every NATIVE tool call (the BEAM
  `run`_`shell`_`fetch` tools) at the chokepoint in `Workbooks.Agent` →
  `_steps.jsonl`. But agents also run work **inside** WASM components, behind the
  Dock. That work is opaque to the native chokepoint. Can we capture it with an
  EXISTING WASM observability standard (adopt, not author) and land it in the
  SAME ledger?

# Finding: feasible, and the slot already exists

  Wasmex 0.14 runs components via `Wasmex.Components` with WASIp2
  (`WasiP2Options`) AND a typed host-import map (`imports:`). Our Dock
  (`Workbooks.Instance.Imports`) already builds that map as
  =%{"iface-fn" `> {:fn, closure}}`, gated by Policy caps.

  A WASM observability interface is just MORE linked imports. The guest's world
  imports `instrument-enter` / `instrument-exit` (Observe) or the `wasi:otel`
  tracing fns; the host satisfies them with closures — the exact same mechanism
  as `vfs-query` or `llm-complete`. No new runtime machinery.

  Note: `WasiP2Options` provides only the STANDARD WASI set
  (cli/io/clocks/random/filesystem/http). `wasi:otel` is a separate proposal, so
  it links as a CUSTOM import via `imports:`, not via `WasiP2Options`. That's
  fine — component imports are satisfied by name.

# Built: the host sink (`Workbooks.Telemetry.WasmBridge`)

  Provides the `instrument-enter`/`instrument-exit` host pair. On exit it
  appends the span to `_steps.jsonl` in the NATIVE event shape
  (`tool: "wasm:<name>"`, `dur_ms`, `exit_code`, `ts`). Span timing lives in a
  public ETS table because enter/exit are separate component→host crossings.

  Consequence — the unification: `Telemetry.summary/1` and `index/2` already
  read `_steps.jsonl`, so a span emitted from INSIDE a component shows up in the
  per-run summary and the cross-session index with ZERO new query code. One
  ledger, whether the tool ran on the BEAM or inside the sandbox.

  Verified in isolation (no guest needed): nested =enter harvest → enter extract
  → exit extract → exit harvest= produced two correctly-timed `wasm:*` rows that
  `summary/1` rolled up unchanged (`tool_calls: 2, total_ms: 40`).

# Adopt which guest path

  - **Dylibso Observe SDK (recommended now).** Mature, language-agnostic. A
    wasm-to-wasm transform auto-instruments a component so every guest function
    emits the enter/exit pair to a host fn — no guest source changes. Maps
    directly onto `WasmBridge`. Battle-tested today.
  - **wasi:otel proposal (standards-track target).** Cleaner long-term (native WIT,
    real OTel spans/attributes), but early; adopt when it AND Wasmtime/Wasmex
    ship native support. `WasmBridge` is the seam — swap the import names, keep
    the sink.

  Either way the host stays the same. We don't author an observability format.

# Blocked-on / honest TODO

  - [ ] **Guest transform tooling (EXTERNAL).** Running this against a REAL
    component needs the Observe wasm-transform in the build, or a guest compiled
    against the `wasi:otel` world. Not yet in our build pipeline → can't demo
    end-to-end through an actual component yet. The host bridge is complete and
    unit-tested; this is the only gap.
  - [ ] **Wire into `Imports.for_caps`** behind a `telemetry` cap. Needs the run's
    workdir threaded into `for_caps/3` (today it takes caps/vfs/info; the sink
    location is the run workdir). One-line merge of
    `WasmBridge.imports(workdir)` once workdir is passed. Deferred until the
    guest path lands — no point gating an import nothing emits yet.
  - [ ] CPU/epoch cap on component spans (wb-11ck.11/.13) is orthogonal.

# Verdict

  The WASM observability path is a thin host bridge on the import mechanism we
  already have, landing in the one ledger we already query. Adopt Dylibso Observe
  now (when the transform reaches the build), keep `wasi:otel` as the
  standards-track swap. Host side: DONE. Guest side: external tooling.
