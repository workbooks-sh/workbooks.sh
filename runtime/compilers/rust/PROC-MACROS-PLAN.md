# Proc-macros in-sandbox — mechanism + plan (wb-zq4)

NOTE: The big crates.io unlock (serde derive, etc). Scoped from mrustc source + feasibility probes.

## mrustc's NATIVE mechanism (src/expand/proc_macro.cpp)

1. Build the proc-macro crate to a native EXECUTABLE (proc_macro_exe_name).
2. ProcMacroInv: pipe() stdin/stdout, posix_spawn() the executable (line ~1682-1740;
   CreateProcessA on Windows).
3. Exchange TokenStreams over the pipes via a byte protocol (send_symbol/send_int/recv_*).

This is SYNCHRONOUS spawn — which the wasm sandbox forbids (no posix_spawn under wasi).

## THE IN-SANDBOX PATH (BEAM-mediated — the offload lever)

Replace the spawn with a host-import the BEAM implements:

1. Compile each proc-macro crate to WASM (a "proc-macro server": reads the token protocol on
   stdin, writes expanded tokens on stdout — same protocol mrustc already speaks). Our Rust
   lane already does Rust→wasm; proc-macro crates need mrustc's proc_macro shim + the
   foundation crates (proc-macro2 / quote / syn / unicode-ident).
2. PATCH mrustc proc_macro.cpp: replace ProcMacroInv's pipe+posix_spawn with a custom wasi
   host-import, e.g. `wb_proc_macro_expand(name_ptr,name_len, in_ptr,in_len, out_ptr,out_cap) -> out_len`.
   send_*/recv_* serialize to/from a buffer instead of pipe fds. Rebuild mrustc.wasm.
3. RUN mrustc.wasm via wasmex (Elixir wasmtime bindings) with that host function defined —
   NOT the wasmtime CLI (which can't host custom imports). The host fn runs the proc-macro.wasm
   under wasmtime, feeds in_bytes as stdin, returns stdout. ← BEAM offload, policy-gated.
4. Wire the dep pipeline: proc-macro deps → compile to wasm server + register so step 2 finds them.

## FEASIBILITY GATE (probed 2026-06-07)

- proc-macro2 1.0.29 → COMPILES + RUNS in-sandbox (fallback mode; "a + b" → 3 tokens). ✓
- syn 1.0.109 → FAILS to compile on mrustc.wasm (dep_compile_failed). ✗

syn is THE crate serde_derive (and most derive macros) parse with. So the proc-macro path is
GATED on syn compiling — which hits the mrustc ~1.54 ceiling (syn 1.0.10x uses constructs
mrustc rejects). NET: **wb-zq4 (proc-macros) depends on wb-1ec (language ceiling)** — the
spawn→host-import bridge is moot until the proc-macro CRATES (syn-based) actually compile.
Next probes worth trying before committing to the ceiling track: an older syn (0.15/1.0.0x)
+ whether any real derive macro avoids syn, and capturing syn's exact mrustc error (ceiling
feature vs fixable). Until syn compiles, derive macros stay blocked; non-derive lib crates
(serde-core, serde_json) already work.

## RISKS / UNKNOWNS

- syn/serde_derive size + the mrustc ~1.54 ceiling on their newest versions (use prefer-requested
  + older pins; version-fallback helps).
- mrustc proc_macro protocol fidelity across the host boundary (the byte protocol is well-defined
  in proc_macro.cpp; serialize verbatim).
- Switching mrustc execution from the wasmtime CLI to wasmex-with-imports (a runtime change).

None are JIT-class walls — all "just solving it." This is the highest-value remaining unlock.
