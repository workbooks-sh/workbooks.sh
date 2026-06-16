# Rust-in-WASM — capabilities, limitations, and how to mitigate (wb-0sz)

NOTE: The honest contract for compiling Rust to wasm in-sandbox (mrustc.wasm → clang.wasm, no
native rustc). Machine-readable twin: `Workbooks.Compilers.RustCaps.{capabilities,diagnose}/_`.
If you are an agent or a person about to build something, read this FIRST — it tells you
what the lane can't do and what to do instead, so you don't fight a wall.

## The one-paragraph model

Real Rust compiles + runs ENTIRELY in the wasm sandbox: no native toolchain, no OS access. The
compiler is mrustc (a from-scratch Rust→C compiler) targeting ~Rust 1.74, then clang.wasm →
wasm. That buys safety and portability; it costs a few hard edges. Most edges have a cheap
mitigation (pin a version, import a derive directly). A few are lifted by the BEAM doing what
wasm can't — the "offload" lever — and that's deliberate, not a hack.

## WHAT WORKS (compile + run, verified on real crates.io crates)

- Leaf + multi-file pure-Rust crates; hyphenated names; transitive dep trees.
- Declarative macros (macro_rules!): bitflags, lazy_static, cfg-if, static_assertions, …
- Feature-gated optional deps via explicit dep_features (cargo-style activation).
- PROC-MACRO DERIVES — executed in-sandbox (serde, derive-new, …), auto-routed through the BEAM.
- Data-table crates (unicode-width, regex-syntax), anyhow, once_cell, log, bytes.
- Full std (alloc/collections/fmt/io over a wasi shim); i128 (emulated).

## WHAT DOESN'T — and the mitigation (the part to communicate)

Each row is also returned by RustCaps.diagnose/1 with category + mitigation when a build fails.

1. LANGUAGE CEILING (~mrustc 1.74).  edition 2024, some GATs, the newest syntax → rejected.
   Symptom: "Unexpected token", "TOK_RWORD_*", or every dep version failing to compile.
   MITIGATE: pin an OLDER crate version (its source predates the construct). Big crates' newest
   releases pull syn 2.0 / edition 2024 — go back far enough. BEAM-offload: NO (needs newer mrustc).

2. NO BUILD-SCRIPT CODEGEN.  build.rs that generates code (include!(env!("OUT_DIR"))), bindgen,
   or compiles bundled C → unsupported. (autocfg-style build.rs is fine: skipped, cfgs fall back.)
   Symptom: missing generated module / OUT_DIR errors.
   MITIGATE: pin a version that doesn't codegen, or vendor the generated file.
   BEAM-offload: YES (planned, wb-iht) — same lever as proc-macros: run the build script in-sandbox,
   pre-open OUT_DIR.

3. VERSION RESOLUTION WINDOW.  the resolver tries the exact pin + the 6 newest in-range versions.
   If the only compilable version is older than that window, a bare `dep` fails.
   Symptom: dep_compile_failed across several versions, or no_matching_version.
   MITIGATE: PIN explicitly — `regex@1.5.4`, not `regex`. BEAM-offload: NO (resolver tuning, wb-rxi).

4. PROC-MACRO RE-EXPORTS.  `use serde::Serialize; #[derive(Serialize)]` fails (serde re-exports
   serde_derive's derive; mrustc doesn't resolve re-exported derives).
   Symptom: "Failed to apply #[derive] - Missing handlers for X".
   MITIGATE: import the derive DIRECTLY from its *_derive crate — `use serde_derive::{Serialize,
   Deserialize};` — and enable the parent's `derive` feature so it's pulled. BEAM-offload: NO
   (mrustc resolve/index.cpp TODO; tracked wb-5bv). serde_derive must be ≤ 1.0.156 (syn 1.x, ed2015).

5. NO THREADS / LIMITED ATOMICS.  wasm32 is single-threaded, no 64-bit atomics. std::thread,
   rayon, thread-based tokio → won't work.
   MITIGATE: single-threaded code; model concurrency on the host (BEAM), not inside the wasm.
   BEAM-offload: PARTIAL — the host can mediate fan-out/async, not run threaded crates transparently.

6. NO RAW IO / NET.  std::net, std::fs, sockets, wall-clock IO don't reach the OS at runtime.
   MITIGATE: use the DOCK host capabilities — browse-fetch (network), llm-complete, vfs-query —
   Policy-gated functions the BEAM implements. BEAM-offload: YES (this is the model; compiled-Rust
   wiring is wb-1mv — declare extern imports, run under Wasmex with allow_undefined).

## THE BEAM OFFLOAD LEVER (what "offshore it safely" means here)

wasm can't spawn, open sockets, or run a native subprocess. Instead of widening the sandbox, the
BEAM provides Policy-GATED host functions and runs the privileged bit itself. A program only gets
the capabilities the Policy grants — request one it doesn't, and the module fails to instantiate.
Already lifted this way:
- PROC-MACRO EXECUTION — the proc-macro server wasm runs host-side (Workbooks.ProcMacroHost); the
  user compile auto-routes through Wasmex when a dep is a proc-macro crate. (No CLI; custom imports.)
- NETWORK / LLM / VFS — Dock host functions (host/instance/imports.ex), gated by Policy.

Candidates to lift next, same lever: build-script execution (wb-iht), mediated net/IO for compiled
core wasm (wb-1mv).

## HOW THIS IS COMMUNICATED

- Programmatic: every rust_compile_to_wasm failure is logged with a classified hint, and any caller
  can get %{category, summary, mitigation} from Workbooks.Compilers.RustCaps.diagnose(error).
- This doc: the same facts in prose, the source of truth for skills/agents.
- Keep both in sync when an edge moves (e.g. when wb-iht lands, flip build.rs from limitation to
  supported in BOTH this file and rust_caps.ex).
