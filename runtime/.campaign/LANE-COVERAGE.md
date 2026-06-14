# Forge lane coverage matrix

Reproducibility + test coverage for the ~23 from-source capability lanes the Forge campaign built.
Derived by listing `compilers/*/build.sh` against `test/*_lane_test.exs`.

- **Provision them all:** `cd runtime/compilers && ./provision-all.sh` (default `SKIP_HEAVY=1` = FAST lanes
  only; `SKIP_HEAVY=0` for the heavy ones; `ONLY=lua,yq` for a subset).
- **Test them all (once provisioned):** `cd runtime && mix test --include build`
  (the `:build` lane tests are `@tag :build`, skip-guarded — excluded from the normal `mix test`).
- **Test one lane:** `mix test test/<name>_lane_test.exs --include build`.

Lane = `compilers/<name>/`. "build.sh" = has an idempotent source-fetch/stage (or Go cross-compile) script.
"test" = a skip-guarded `:build` lane test that compiles via `build_c_dir` / runs the staged artifact.

| Lane | build.sh | test file | source | domain |
|---|---|---|---|---|
| yq | yes | yq_lane_test | Go → wasip1 (native) | YAML processor |
| gojq | yes | gojq_lane_test | Go → wasip1 (native) | jq for JSON |
| dasel | yes | dasel_lane_test | Go → wasip1 (native) | JSON/YAML/TOML/XML/CSV query |
| jsonnet | yes | jsonnet_lane_test | Go → wasip1 (native) | config templating language |
| esbuild | yes | esbuild_lane_test | Go → wasip1 (native) | JS/TS bundler |
| lua | yes | lua_lane_test | C-from-source (build_c_dir) | Lua 5.4 scripting language |
| zstd | yes | zstd_lane_test | C-from-source (build_c_dir) | compression |
| miniz | yes | miniz_lane_test | C-from-source (build_c_dir) | ZIP/gzip archive handling |
| monocypher | yes | monocypher_lane_test | C-from-source (build_c_dir) | crypto (Ed25519/Blake2b/ChaCha20) |
| stb | yes | stb_image_lane_test | C-from-source (build_c_dir) | image decode (PNG/JPEG/...) |
| stbwrite | yes | stbwrite_lane_test | C-from-source (build_c_dir) | image encode/generate (PNG/JPG) |
| stbtt | yes | stbtt_lane_test | C-from-source (build_c_dir) | TrueType font rasterization |
| pcre2 | yes | pcre2_lane_test | C-from-source (build_c_dir) **[HEAVY]** | Perl-compatible regex |
| gumbo | yes | gumbo_lane_test | C-from-source (build_c_dir) | HTML5 parser → DOM |
| expat | yes | expat_lane_test | C-from-source (build_c_dir) | XML streaming/SAX parser |
| treesitter | yes | treesitter_lane_test | C-from-source (build_c_dir) **[HEAVY]** | code → AST (real C grammar) |
| minigmp | yes | minigmp_lane_test | C-from-source (build_c_dir) | arbitrary-precision bignum |
| md4c | yes | md4c_lane_test | C-from-source (build_c_dir) | Markdown → HTML |
| utf8proc | yes | utf8proc_lane_test | C-from-source (build_c_dir) | Unicode NFC/NFD/case-fold |
| xdiff | yes | xdiff_lane_test | C-from-source (build_c_dir) | text diffing / unified diff |
| xxhash | yes | xxhash_lane_test | C-from-source (build_c_dir) | fast non-crypto hashing (XXH32/64/XXH3) |
| tinyexpr | yes | tinyexpr_lane_test | C-from-source (build_c_dir) | math-expression evaluator |
| qrcodegen | yes | qrcodegen_lane_test | C-from-source (build_c_dir) | QR code generation |
| **duckdb** | **NO** (see drift) | duckdb_lane_test | C++-from-source → prebuilt `duckdb.wasm` | full SQL engine |

23 lanes have BOTH a `build.sh` and a `:build` test — fully reproducible + covered.

## Naming note (not drift)
The lane dir and the test file don't always share a stem; the matrix above already reconciles them:
`stb` → `stb_image_lane_test`. All other lanes match `compilers/<name>/` ↔ `test/<name>_lane_test.exs`.

## Drift

1. **duckdb — test but no `build.sh`.** `compilers/duckdb/` ships a **prebuilt `duckdb.wasm` (~34MB)** plus
   `ddb-link.sh` (link step) and `ddbq.sh` (query driver); there is no idempotent fetch/stage `build.sh`, so
   the C++-from-source provision is **not reproducible via `provision-all.sh`** and the artifact is committed
   instead of regenerated. This is the one true reproducibility gap. Reason: the DuckDB amalgam is the single
   machine-threatening build on this box (the ~25MB-TU codegen that OOMs clang.wasm — see CRASH-PROTOCOL.md),
   so it was built out-of-band and the artifact pinned. **Follow-up:** add a bounded, split-TU
   `compilers/duckdb/build.sh` (timeout + `ulimit -v` + `WB_CC_CONC`) so the SQL lane is reproducible from
   source like the rest.

No lane is missing a test. Every `*_lane_test.exs` has a corresponding lane dir.

## Non-capability dirs under `compilers/` (excluded from the sweep)
These are the compiler **toolchains** / wrappers the lanes build *on*, not from-source capability lanes —
`provision-all.sh` skips them (they have their own, often long, provisioning flows):
`c`, `clang`, `go`, `rust`, `zig`, `wasm-tools`, `js`, `svelte`.
(`svelte_lane_test` + `js_dock_lane_test` exist and run through the `js`/`esbuild` lanes; they need no
separate from-source provision.)
