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

## UPDATE — Option B SPIKED: it's a strict win (0.034ms)

The naive measurement used a wasi COMMAND (re-instantiated per call). The reactor approach — a wasm
module instantiated ONCE, exports called many times — was spiked and **proven**:

| Path | Per-call |
|---|---|
| subprocess `work.wasm` | 8.3 ms |
| in-process Elixir `WorkCore` (today) | 0.13 ms |
| **Zig reactor via Wasmex (Option B)** | **0.034 ms** ✓ |

The Zig parser compiled to wasm is FASTER than the Elixir one even with the Wasmex marshal overhead,
and the output matches `WorkCore` exactly (`match: true`). So Option B is not a trade-off — it's
faster AND DRY. **New recommendation: do Option B.** `reactor/src/lib.zig` is the reactor (alloc/reset/
parse_units, a pointer-len string ABI, 8KB wasm); nexus instantiates it once and calls it. The
remaining work: export the rest of the toolchain (graph/wit/weave/audit) the same way, repoint nexus's
`WorkCore.*` calls, delete `work_core`.

## Recommendation (superseded — see UPDATE above)
Don't do the naive deletion (60× slower). **Option A now** (conformance corpus — cheap, removes the
drift risk immediately), and treat **Option B as a scoped follow-up** when the toolchain stabilises —
it's the architecturally-right end state, but it's a focused build, not a one-commit deletion.

## What IS done in Z4
- ✅ The runtime escript is retired (deleted with `runtime/`).
- ✅ `cli-release` rewired for the Zig CLI (cross-compiles native + wasm, ReleaseSmall ~198KB/108KB).
- ✅ The installer (`web/cli.sh`) already matches the Zig asset names.
- ✅ Option A DONE — shared conformance corpus (reactor/src/corpus/ + units.golden); both the Elixir and
  Zig parsers are tested against the one golden, so they cannot silently diverge (DRY-in-behaviour).
- ◻ Option B (Zig toolchain as a wasm component) — the scoped follow-up for literal one-toolchain.

## Progress + two caveats found while wiring it up

**Done:** the reactor exports `parse_units` + `parse_json` (full nodes); `Nexus.Toolchain` instantiates
it once and the server parses `.work` through the **same Zig code the CLI runs**. Structural conformance
(code units: name/kind/lang) matches `WorkCore` exactly, in nexus, at 0.034ms/call.

**Two caveats that mean a *full* `work_core` deletion is not a clean one-shot:**
1. **Ref-token parity.** `WorkCore.Literate.refs` extracts `[[backlinks]]` **and** `:atoms` / `@types`
   / `#tags` (and even pulls a unit's own name atom — arguably a quirk). The Zig parser does
   `[[backlinks]]` only. The units match; the *refs* don't yet. `graph`/`check`/`why`/`near` depend on
   refs, so they can't move to the reactor until the Zig ref extraction matches (or `WorkCore`'s quirk
   is fixed and both align). Tractable, but real.
2. **`Extract.Elixir` is genuinely Elixir-bound.** It uses `Code.string_to_quoted` (the Elixir compiler's
   AST) to pull a unit's exports/types/calls — used by `Graph` + `Wit`. There is **no Zig equivalent**
   (Zig can't parse Elixir's AST). So this piece legitimately stays Elixir; it is *not* drift, it's a
   thin Elixir-runtime adapter.

**Therefore the honest end-state** isn't "delete `work_core` entirely" — it's: the **shared `.work`
parse** lives in the one Zig reactor (the big duplicated logic, now DRY + faster, used by both CLI and
server), and `work_core` shrinks to the **genuinely-Elixir-specific** bits (`Extract.Elixir` + the
AST-dependent `Graph`/`Wit`). That's the right granularity — DRY where it can be, Elixir where it must be.
