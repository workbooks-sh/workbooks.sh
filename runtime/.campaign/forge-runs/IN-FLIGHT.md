# In-flight background agents (update on launch + completion)

Kill a runaway with `TaskStop <agentId>`. On resume, re-launch any that `failed` without a verdict.

| agentId | mission | checkpoint | status |
|---|---|---|---|
| a3386da7a380ec9bc | light sweep2: diverse small libs (cJSON/tomlc99/tinyexpr/utf8proc + a Rust crate) | forge-runs/light-sweep2.md | running (light, reliable) |
| aa992f6f8fa8a5bc7 | DuckDB to-live (heavy full build) | forge-runs/duckdb-tolive.md | DIED early (no checkpoint, 3rd heavy agent killed by crashes) — DuckDB to-live DEFERRED to a stable box; stays proven |
| ac2172afdee7a1851 | light sweep: SIMD-intrinsic runtime proof + C leaf-lib vein | forge-runs/light-sweep.md | DONE — SIMD intrinsics LIVE + 4 C libs (xxHash/miniz/cmark/libyaml) proven; committed |
| (orphaned ab497938) | DuckDB conc-2 detached build | n/a | DEAD (0 procs); revealed real portability errors (mbedtls entropy, fcntl F_*LCK) — folded into the to-live agent |

## Recently completed (this session)
- rayon-core + llvm.wasm.* codegen patch → **LIVE**, committed `d32f9437` (verified through crash recovery).
- DuckDB split-amalgamation → **proven** (compiles 9/9; full build RAM-bound). Recipe: forge-runs/duckdb-recipe.md.
- Rust threads, Rust SIMD (-msimd128), C++ exceptions (both lanes), Go/esbuild → live.

_Convention: heavy builds (mrustc rebuild, DuckDB-scale) run SOLO + resource-bounded; ≤1 heavy build at a
time on this RAM-sensitive box. Light single-file/single-crate compiles can share._
