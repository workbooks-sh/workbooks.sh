# In-flight background agents

Kill a runaway with `TaskStop <agentId>`. On resume, re-launch any that `failed` without a verdict.

**STATUS: loop paused; ONE focused background effort running.**

| agentId | mission | checkpoint | status |
|---|---|---|---|
| a5e69fdceb467229e | DuckDB to-live — INCREMENTAL .o-caching build (only recompile failing TUs), time-boxed ~60-90min, resumable via the .o cache | forge-runs/duckdb-tolive2.md | running (background) |


## Session result — Forge campaign (banked, see FORGE-CAPABILITIES.md)
- **LIVE (14):** C, C++ (+exceptions, both lanes), Zig, Rust, Rust threads, Rust SIMD, wasm SIMD intrinsics,
  rayon-core, C/pthread threads, Go/esbuild, SQLite, crates.io deps.
- **PROVEN:** 12 C leaf-libs (9 domains); DuckDB (compiles, reached link).
- Levers: `--cfg target_feature=atomics`, the mrustc codegen patch (`mrustc-patch/`), `WB_CC_CONC`, crash protocol.

## Deferred (dedicated-session work, NOT loop work)
- **DuckDB to-live** — NOT a one-line fix (verified): fcntl `F_*LCK` (-D-able) + a libc++ `ldiv_t`
  `#include_next` breakage on duckdb-5/6/42/mbedtls (sensitive to defines; same class as the C++ EH build).
  Needs `build_c_dir` include-handling matched precisely + source patches + a clean build on a stable box
  with `.o` caching. Recipe/finding in resolved.json + forge-runs/duckdb-recipe.md.
