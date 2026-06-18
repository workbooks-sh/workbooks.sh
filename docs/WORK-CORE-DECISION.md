# Z4 — the `work_core` question, measured

The loop's north star: "nexus calls the ONE Zig toolchain via wasmex, delete the Elixir `work_core`."
I spiked + measured before charging in. The naive form is a bad trade; the right form is a real
mini-project. Here's the data and the decision.

## The measurement
| Path | Per-call latency |
|---|---|
| In-process Elixir `WorkCore.Literate.parse` (today) | **0.13 ms** |
| Shell to `wasmtime run work.wasm` (the naive "call the Zig CLI") | **8.3 ms** (8.1 precompiled) |

nexus parses on every page render, weave, and check — often many times per request. A **~60×**
per-parse penalty on that hot path is not acceptable. The cost is the wasi **command** model: each
`run` is a fresh `main` (process/instance setup + argv + stdout capture), paid every call.

## So the literal instruction is wrong — but there are two real options

**Option A — keep `work_core`, kill the *drift* with a shared conformance corpus (pragmatic).**
The "drift" is ~600 LOC of parsing logic existing in both Elixir (server) and Zig (CLI/sandbox). They
serve genuinely different runtimes with different perf constraints — that duplication is *defensible*.
Eliminate the **risk** of silent divergence with a shared `.work` fixture corpus + expected outputs
that BOTH implementations are tested against (a CI gate fails if they disagree). DRY in **behaviour**
(one spec, two conformant thin impls), which is the right granularity. Cheap, low-risk, no perf hit.

**Option B — the Zig toolchain as a wasm *component* (the proper zero-drift, fast).**
The naive measurement used a wasi *command* (re-instantiated per call). A wasi **reactor/component**
exporting `parse`/`weave`/`check` functions can be instantiated **once** (`Nexus.Sandbox.start`) and
called many times (`Nexus.Sandbox.call`) — amortizing instantiation to ~µs–low-ms per call. That makes
"nexus uses the one Zig toolchain" both DRY *and* fast. Cost: a real mini-project — build the Zig
toolchain as a component (reactor exports + a string ABI over component-model strings, not a CLI), and
repoint nexus's `WorkCore.*` calls through `Nexus.Sandbox`. Then `work_core` deletes cleanly.

## Recommendation
Don't do the naive deletion (60× slower). **Option A now** (conformance corpus — cheap, removes the
drift risk immediately), and treat **Option B as a scoped follow-up** when the toolchain stabilises —
it's the architecturally-right end state, but it's a focused build, not a one-commit deletion.

## What IS done in Z4
- ✅ The runtime escript is retired (deleted with `runtime/`).
- ✅ `cli-release` rewired for the Zig CLI (cross-compiles native + wasm, ReleaseSmall ~198KB/108KB).
- ✅ The installer (`web/cli.sh`) already matches the Zig asset names.
- ◻ `work_core` deletion — gated on the decision above (recommend A now, B later).
