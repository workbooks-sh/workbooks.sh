# The Three Walls — canon vocabulary for capability blockers

Every roadmap capability collapses into one of three foundational blockers. Use these names
(not "Wall 1/2/3") so we stop re-deriving the same root causes every session.

## STRUCTURE: 1 boundary + 2 solution services (don't conflate their kinds)
- **BEDROCK is the BOUNDARY**, not a service. It's the non-negotiable seal everything runs inside:
  the guest is sandboxed wasm, in-process (BEAM-as-microVM via embedded wasmtime), NO native, NO JIT,
  no OS process per guest. It doesn't solve anything — it's the constraint the two services respect.
- **FORGE and BRIDGE are the two SOLUTION SERVICES** — real machinery that delivers a capability
  WITHOUT crossing Bedrock. Forge PRODUCES the artifact (compile source→wasi); Bridge ADAPTS the
  runtime to an artifact we didn't produce (broker a prebuilt wasm's env imports).

## ROUTING: pick the service by what you start with
1. Have source? → **FORGE** (compile to wasi).
2. Have only a prebuilt emscripten wasm? → **BRIDGE** (broker its env imports).
3. Neither — a dynamic engine / JIT-shaped thing? → **FORGE the engine itself** into the sandbox,
   jitless (the SpiderMonkey path; the jitless toll IS Bedrock).
4. Native-only (arbitrary user binary / a JIT that must emit native)? → **past Bedrock = out** (the
   only escape was the OS microVM, permanently refused). Honest roadmap, stop re-attempting in-guest.

## 🪨 BEDROCK — no native execution in the sandbox
The **guest** (untrusted code in the wasm sandbox) can never generate or run native code at
runtime (W^X / no JIT). That seal IS the security boundary — it's a hard wasm invariant, not a
gap we can close in-guest.

BUT the **host** (the Elixir/BEAM runtime) is an ordinary native process — it CAN load + run
native code at runtime (NIFs via dlopen; ports/native binaries; its own BeamAsm JIT). So a
Bedrock capability is not "impossible" — it's **"can't run as untrusted guest code; can only run
as a TRUSTED HOST SERVICE brokered across the membrane"** (same pattern as HTTP/exec/net brokers).

Two escapes (the dividing line is TRUST):
1. **Trusted host service** — trust the *implementation*, only the *input* is the user's
   (e.g. a real V8 / JS-eval engine, ML inference, GPU compute, a JVM). The guest asks the host;
   the guest never runs native. Fits our broker model cleanly.
2. **The microVM tier** — run the user's *arbitrary* untrusted native in an isolated VM. The only
   escape when even the code is untrusted. **Rejected** (we chose the container/broker model).

Members: V8/Deno/Node-native, JVM, JIT engines, native binaries, GPU compute.

## 🌉 THE BRIDGE — no browser/JS host environment
A huge ecosystem ships wasm built by **Emscripten / wasm-bindgen** that imports browser + JS glue
(DOM, Web Workers, the emscripten `env` runtime) instead of clean wasi. We have no host providing
those imports, so that wasm won't instantiate.

Escape: **build a headless Emscripten/JS host on the BEAM** — implement the emscripten `env` /
JS-glue imports host-side (broker pattern). Buildable.

**SCOPED 2026-06-13 — the Bridge is NARROWER than it looks; most of it is FORGE in disguise:**
- A trivial C program → `wasm32-wasi` imports only `wasi_snapshot_preview1` (fully satisfied today).
- We already ship a clean-wasi `sqlite.wasm` (imports only `wasi_unstable`) — Forge-done, just needs
  wiring as a CommandRegistry `command`. SQLite was never a Bridge problem.
- `emcc -sSTANDALONE_WASM -fwasm-exceptions` collapses the emscripten `env` surface to ~5 trivial
  shims (memory, abort, __assert_fail, emscripten_resize_heap, indirect_function_table) + wasi. The
  HARD imports (DOM/WebGL/Web-Workers, `EM_ASM` inline-JS via `emscripten_asm_const_*`) appear only
  in libs that touch the browser — headless compute libs (NumPy core, DuckDB engine, sqlite) don't.
- The broker mechanism ALREADY EXISTS: `host/js_dock.ex` instantiates a guest under Wasmex with a
  custom Policy-gated `env` import table. An **`EmscriptenDock`** is a sibling clone (~15 `env.*`
  shims + wasi passthrough). Hooks into `package_manager.ex` run/route by import detection (~L987).
- **Genuine emscripten-only residue (true Bridge): DuckDB-wasm, esbuild-wasm, ONNX-web.** Everything
  else — SQLite (done), NumPy/OpenCV *core*, general C/C++ — is a **Forge** from-source wasi rebuild
  on the clang lane.
- **wasm-bindgen is a SEPARATE, harder problem** (per-crate generated JS shim holding a live JsValue
  heap — needs a real JS engine). Its answer is also Forge: rebuild the Rust crate to wasm32-wasip1
  WITHOUT wasm-bindgen (target the non-web feature set).

**Order of attack:** (1) import-audit the prebuilt DuckDB/esbuild/OpenCV binaries (`wasm-tools print |
grep '(import'`) — the decision gate: easy/medium env surface → EmscriptenDock; DOM/Worker/asm_const →
stays roadmap. (2) Wire the already-built sqlite.wasm (Forge). (3) Build EmscriptenDock (M) only for
audit-confirmed-tractable targets. Precedent file to clone: `host/js_dock.ex`.

**AUDIT RESULT 2026-06-13 (empirical, wasm-binary level) — the Bridge is even narrower; lean FORGE:**
NONE of the three residue libs is EmscriptenDock-able as shipped — all carry browser-bound imports no
build flag removes:
- **DuckDB-wasm** (best `-eh` build): emscripten `MAIN_MODULE` dynamic-linking (268 `GOT.*` + dylink
  section), `EM_ASM` inline-JS (`emscripten_asm_const_*`), 14 `embind`/`emval` live-JS marshalling, 17
  JS-implemented `duckdb_web_fs_*`. → roadmap as a prebuilt; **Forge it: compile DuckDB C++ source →
  wasm32-wasi (needs C++ EXCEPTIONS — gated on that Forge build).**
- **esbuild-wasm**: it's a **Go→WASM** binary (`syscall/js`), not emscripten/wasi at all. → **Forge it:
  rebuild `GOOS=wasip1 GOARCH=wasm` (clean wasi). Needs a Go→wasip1 toolchain in the lane (Forge gap).**
- **ONNX-web 1.26**: ships only threaded builds (shared memory + Web-Worker spawn); no standalone. →
  honest roadmap until upstream publishes a wasi/single-threaded artifact.

**Consequence:** the Bridge/EmscriptenDock is a NARROW auxiliary — valid only for *self-compiled*
`-sSTANDALONE_WASM -fwasm-exceptions` modules, NOT the vendor CDN ecosystem (it's too browser-coupled).
**FORGE is the workhorse.** C++ exceptions is the KEYSTONE (unblocks C++-from-source incl. DuckDB); a
Go→wasip1 toolchain unblocks esbuild + the Go ecosystem. Don't build EmscriptenDock as a headline bet.

## 🔨 THE FORGE — toolchain completeness
Our own in-sandbox compilers can't yet *produce* certain wasm. Not a wall — each is a build, and
it's our home turf (where effort reliably converts to live capability).

Members:
- mrustc frozen at 1.74 + `target_feature=false` → edition-2024, proc-macros (roadmap). **Rust threads:
  PROVEN 2026-06-13 WITHOUT a fork** — pass `--cfg target_feature=atomics` (mrustc's cfg.cpp checks CLI
  `--cfg` before the hardcoded false callback, so `target.cpp:746` is bypassed, not patched) + a 2-file
  std TLS patch. 4-thread Rust runs to exactly 1,000,000. The "no mrustc fork" stance HOLDS. **LIVE** —
  `compile_rust_threads` lane wired + green test; reproducible threads-libstd build.
- **wasm SIMD (v128) → LIVE** (`rust_compile_to_wasm(simd: true)`): `-msimd128 -O2` autovectorizes the
  user-code C compile (mrustc lowers Rust SIMD intrinsics to scalar C, so autovec — not `--cfg` — is the
  path; `-O2` required). Proven: saxpy 0→12 v128 ops, test green.
- **The `--cfg` lever is NOT universal** (proven): it unlocks ONLY threads/atomics. edition-2024 is a
  PARSER ceiling (mrustc crashes on `gen` blocks), proc-macros are a separate mechanism.
- **rayon (rayon-core) → LIVE** + **the `llvm.wasm.*` intrinsic wall cleared**: a surgical, user-authorized
  mrustc-SOURCE patch (`codegen_c.cpp`) lowers the wasm futex intrinsics (`memory.atomic.wait32/wait64/
  notify`) + ~30 SIMD intrinsics to `__builtin_wasm_*` instead of aborting. rayon_core::join on 4 threads =
  499999500000 (test green). Reproducible via `compilers/rust/mrustc-patch/` (apply script wired into
  provision). This is the FIRST deliberate mrustc-source patch — surgical + reproducible, NOT a divergent
  fork; the "no mrustc fork" stance is relaxed for upstreamable codegen-completeness patches. (Top-level
  `rayon` par_iter sugar still blocked — mrustc trait-resolution ceiling; use rayon-core's join/scope.)
  The lowered SIMD intrinsics are now RUNTIME-PROVEN too (i8x16_bitmask/swizzle/u8x16_narrow/all_true/
  any_true correct via `rust_compile_to_wasm(simd: true)`; rust_simd_test.exs).
- ~~no EH-enabled libc++ → C++ exceptions~~ → **PROVEN 2026-06-13** (from-source EH runtime via our
  clang.wasm: llvmorg-22.1.0 libcxxabi/libunwind built `-fwasm-exceptions -mllvm
  -wasm-use-legacy-eh=false` → `libc++abi-eh.a`+`libunwind-eh.a`; throwing C++ catches with full
  unwinding). KEYSTONE — unblocks C++-from-source-to-wasi (DuckDB-class). Wiring to live in progress.
- no Go compiler → Go ecosystem: **scoping now** — Go's native `GOOS=wasip1` emits clean wasi (esbuild
  the headline). Likely a provision-time build tool producing staged .wasm (like prebuilt sqlite).
- no Fortran / OCaml / etc. → those ecosystems (roadmap)

## How to use this
- Tag every `roadmap` capability in resolved.json with its wall (bedrock | bridge | forge).
- BEDROCK items: decide per-item if a trusted host-service broker is acceptable; otherwise they
  stay roadmap (microVM rejected). Don't keep re-attempting them in-guest.
- BRIDGE: the current strategic frontier — build the headless Emscripten host.
- FORGE: steady build work; converts to live with effort + the occasional stall risk (mrustc).
