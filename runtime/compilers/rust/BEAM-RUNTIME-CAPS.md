# BEAM-mediated runtime capabilities for in-sandbox code (wb-1mv)

NOTE: The offload lever — give untrusted in-sandbox programs network/IO via host functions
the BEAM implements + Policy-gates, instead of raw OS access. Mechanism ALREADY EXISTS.

## What already exists (the Dock — host/instance/imports.ex)

Wasmex.Components-based, Policy-gated host functions a typed component calls:
- `browse-fetch` : NETWORK egress via the host (component never opens a socket) ← the net cap
- `llm-complete` : LLM call (host holds the key)
- `vfs-query`    : SQL against the Instance's SQLite VFS
- `run-command`  : invoke a registered in-WASM command (argv+stdin→stdout)

Capability gating is by construction: the host only provides imports the Policy grants;
a component importing a non-granted cap fails to instantiate. This IS the BEAM-offload
model the project wants — untrusted code gets mediated capabilities, not raw syscalls.

## The gap (wb-1mv)

The Dock is wired for TYPED COMPONENTS (Wasmex.Components, WIT world). The compiled-language
lanes (C/Zig/Rust/JS/Go/TS) produce CORE wasm command modules run via the wasmtime CLI
(PackageManager.run) — they reach the Dock's network/llm/vfs only if run through Wasmex with
those imports. So a compiled Rust program can't yet call browse-fetch.

## Plan to bridge (concrete)

1. A Rust "dock" shim crate: declare the Dock fns as extern imports
   (e.g. `extern "C" { fn browse_fetch(ptr,len) -> ...; }`) under a known import module.
2. Link the compiled wasm with `--allow-undefined` so those imports survive (add an opt to
   Compilers.rust_compile_to_wasm).
3. Run the core wasm via Wasmex.Instance with a core-import map exposing the Dock fns
   (Policy-gated, same closures as imports.ex), instead of the wasmtime CLI.

This gives compiled untrusted Rust BEAM-mediated network/IO — covers the tokio-class
"runtime capability" need WITHOUT giving raw sockets/threads, and is NOT ceiling-blocked.
(tokio itself still needs a wasi/BEAM-backed executor; but mediated net/IO is the 80%.)

## Why this matters

Runtime caps are a POLICY choice, not a wall (per the full-extent map). The hard part —
a safe, host-mediated capability surface — is already built (the Dock). wb-1mv is wiring,
not research.

## BLOCKER found (2026-06-07) — Wasmex can't load our exceptions-using wasm

Step 1 works: allow_undefined makes host imports survive (env::host_double verified). But
running the wasm via Wasmex.start_link FAILS: "exceptions proposal not enabled". Our Rust wasm
is built with -fwasm-exceptions (libstd's setjmp/longjmp / sjlj). The wasmtime CLI enables it
(-W exceptions=y); Wasmex 0.14's EngineConfig exposes only consume_fuel / cranelift_opt_level /
wasm_backtrace_details / memory64 / wasm_component_model — NO exceptions-proposal flag.

RESOLUTION PATHS (each non-trivial):
1. Enable the exceptions proposal in Wasmex (upgrade/patch the wasmex NIF EngineConfig).
2. Build a no-exceptions Rust variant (rebuild libstd panic=abort, drop -fwasm-exceptions /
   -lsetjmp). Big libstd rebuild; loses unwinding.
3. A host other than Wasmex that supports exceptions + custom imports (the wasmtime CLI does
   exceptions but NOT custom Elixir imports — dead end).

So wb-1mv (compiled-Rust → BEAM caps) is BLOCKED on the wasm-exceptions/Wasmex mismatch. The
Dock itself (typed components) is unaffected — it already runs via Wasmex.Components. Needs a
deliberate decision (patch wasmex vs no-exceptions libstd), not a bounded loop increment.
