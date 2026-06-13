# The Three Walls — canon vocabulary for capability blockers

Every roadmap capability collapses into one of three foundational blockers. Use these names
(not "Wall 1/2/3") so we stop re-deriving the same root causes every session.

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
JS-glue imports host-side (broker pattern). Buildable. Biggest locked-up value in one place.

Members: NumPy, OpenCV, ONNX/TFLite, Skia, DuckDB-wasm, most JS bundlers (Biome/Rollup/esbuild-wasm).

## 🔨 THE FORGE — toolchain completeness
Our own in-sandbox compilers can't yet *produce* certain wasm. Not a wall — each is a build, and
it's our home turf (where effort reliably converts to live capability).

Members:
- mrustc frozen at 1.74 + `target_feature=false` → Rust threads, edition-2024, proc-macros
- no EH-enabled libc++ → C++ exceptions
- no Go / Fortran / OCaml / etc. compiler → those language ecosystems

## How to use this
- Tag every `roadmap` capability in resolved.json with its wall (bedrock | bridge | forge).
- BEDROCK items: decide per-item if a trusted host-service broker is acceptable; otherwise they
  stay roadmap (microVM rejected). Don't keep re-attempting them in-guest.
- BRIDGE: the current strategic frontier — build the headless Emscripten host.
- FORGE: steady build work; converts to live with effort + the occasional stall risk (mrustc).
