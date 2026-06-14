# Forge capabilities — what the wasm sandbox can do (canonical summary)

The single scannable answer to "where are we." Verdict ladder: **roadmap** (not solved) < **proven**
(works in an experiment) < **wired** (in a lane) < **live** (lane + green test). Source of record:
`.campaign/resolved.json`; the walls model: `.campaign/WALLS.md`.

## LIVE — wired + green test, runs in-sandbox

| Capability | Lane | Proof |
|---|---|---|
| C → wasi | clang.wasm | the C lane |
| C++ (STL/RTTI, no-exceptions) | clang.wasm `-x c++` | cpp_lane_test |
| **C++ exceptions** (try/throw/catch + RAII unwind) | from-source EH libc++ (`compile_cpp`/`build_c_dir`) | cpp_lane_test 3/3 — single- AND multi-file |
| Zig → wasi | zig1.wasm → clang.wasm | zig lane |
| Rust (single-thread) → wasi | mrustc → clang.wasm | build_to_tool_test |
| **Rust threads** (std::thread, Arc<Atomic>) | `compile_rust_threads` + threads libstd | rust_threads_lane_test (4 threads → 1,000,000) |
| **Rust SIMD** (autovec v128) | `rust_compile_to_wasm(simd: true)` `-msimd128 -O2` | rust_simd_test |
| **wasm SIMD intrinsics** (llvm.wasm.*) | mrustc codegen patch → `__builtin_wasm_*` | rust_simd_test (bitmask/swizzle/narrow…) |
| **rayon-core** (data-parallel Rust) | threads lane + dep lane + codegen patch | rust_rayon_lane_test (join → 499999500000, 4 threads) |
| C/pthread threads (shared-mem) | `compile_threads` wasm32-wasi-threads | threads_lane_test |
| **Go → wasi** | native `GOOS=wasip1` (provision-time) | go_wasip1 |
| **esbuild** (JS/TS bundler) | Go-wasip1 artifact | wired in JS/TS/Svelte lanes (~23min QuickJS → ~0.4s) |
| **yq** (YAML processor) | Go-wasip1 artifact | yq_lane_test (.name/.tags through PackageManager.run) |
| **gojq** (jq for JSON) | Go-wasip1 artifact | gojq_lane_test (filter/arithmetic/raw) |
| **dasel** (JSON/YAML/TOML/XML/CSV query) | Go-wasip1 artifact | dasel_lane_test (3 formats) |
| **jsonnet** (config templating language) | Go-wasip1 artifact | jsonnet_lane_test (arith/comprehension/stdlib) |
| SQLite | clean-wasi prebuilt | ships in-tree |
| crates.io dep (real crate) | Rust dep lane | itoa@1.0.11 fetched+compiled+ran |
| **DuckDB** (full SQL engine) | from-C++-source -> wasi | duckdb_lane_test (CREATE/INSERT/SELECT GROUP BY, 34MB wasm) |
| **Lua 5.4** (scripting language) | from-C-source -> wasi (build_c_dir) | lua_lane_test (arith/math/loop) |
| **zstd** (compression) | from-C-source -> wasi (build_c_dir) | zstd_lane_test (compress/decompress roundtrip) |
| **monocypher** (crypto: Ed25519/Blake2b/ChaCha20) | from-C-source -> wasi (build_c_dir) | monocypher_lane_test (sign/verify/tamper) |
| **stb_image** (image decode PNG/JPEG/...) | from-C-source -> wasi (build_c_dir) | stb_image_lane_test (decode PNG) |
| **PCRE2** (Perl-compatible regex) | from-C-source -> wasi (build_c_dir) | pcre2_lane_test (match + capture groups) |
| **gumbo** (HTML5 parser -> DOM) | from-C-source -> wasi (build_c_dir) | gumbo_lane_test (parse + extract text) |
| **libexpat** (XML streaming/SAX parser) | from-C-source -> wasi (build_c_dir) | expat_lane_test (parse + extract) |
| **miniz** (ZIP/gzip archive handling) | from-C-source -> wasi (build_c_dir) | miniz_lane_test (ZIP create/read/extract) |
| **tree-sitter** (code -> AST, real C grammar) | from-C-source -> wasi (build_c_dir) | treesitter_lane_test (parse C source) |
| **mini-gmp** (arbitrary-precision bignum) | from-C-source -> wasi (build_c_dir) | minigmp_lane_test (2^200, 30!) |
| **stb_image_write** (image encode/generate PNG/JPG) | from-C-source -> wasi (build_c_dir) | stbwrite_lane_test (encode->decode roundtrip) |
| **md4c** (Markdown -> HTML) | from-C-source -> wasi (build_c_dir) | md4c_lane_test (render headings/emphasis/links) |
| **utf8proc** (Unicode NFC/NFD/case-fold) | from-C-source -> wasi (build_c_dir) | utf8proc_lane_test (casefold + NFC) |
| **xdiff** (text diffing / unified diff) | from-C-source -> wasi (build_c_dir) | xdiff_lane_test (diff -> unified hunk) |
| **xxHash** (fast non-crypto hashing XXH32/64/XXH3) | from-C-source -> wasi (build_c_dir) | xxhash_lane_test (deterministic digests) |
| **tinyexpr** (math-expression evaluator) | from-C-source -> wasi (build_c_dir) | tinyexpr_lane_test (expr + bound vars) |
| **stb_truetype** (font rasterization) | from-C-source -> wasi (build_c_dir) | stbtt_lane_test (rasterize glyph) |
| **qrcodegen** (QR code generation) | from-C-source -> wasi (build_c_dir) | qrcodegen_lane_test (encode URL -> matrix) |

## PROVEN — ran in an experiment, not yet wired+tested

| Capability | Lane | Note |
|---|---|---|
| **12 C leaf-libs** | `build_c_dir` | zstd, brotli, md4c, tinyscheme, xxHash, miniz, cmark, libyaml, cJSON, tinyexpr, tomlc99, utf8proc (9 domains). Recipes in resolved.json |

## ROADMAP — not reachable in-guest (the walls)

- **BEDROCK** (no native exec in the sandbox): V8/Deno JIT, JVM, native binaries, GPU compute. Only via a
  trusted host-service broker, or the rejected microVM. Engines must be compiled-to-wasm jitless (SpiderMonkey).
- **BRIDGE** (no browser/JS host): prebuilt emscripten/wasm-bindgen libs (DuckDB-wasm, ONNX-web) — browser-bound.
  Forge-rebuild from source instead where possible.
- **FORGE ceilings** (mrustc parser limits, NOT `--cfg`-fixable): Rust edition-2024 (`gen` blocks crash mrustc),
  proc-macro language features; top-level `rayon` par_iter sugar (trait-resolution ceiling — use rayon-core).

## Session levers worth remembering
- **mrustc `--cfg target_feature=atomics`** bypassed the hardcoded target_feature=false → Rust threads, NO fork.
- **mrustc codegen patch** (`compilers/rust/mrustc-patch/`) lowers llvm.wasm.* intrinsics → rayon + SIMD intrinsics.
  Surgical + reproducible mrustc-source patches are now allowed (not version-chasing forks).
- **`WB_CC_CONC`** env caps clang-build concurrency so heavy C++ (DuckDB) doesn't OOM.
- **Crash resilience** (`.campaign/CRASH-PROTOCOL.md`): commit every win immediately; heavy agents die on this
  box (light agents land) — heavy builds run as bounded background bash, ≤1 at a time.
