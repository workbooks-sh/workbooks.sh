# In-sandbox commands — campaign reference

Every command below runs as a **WASI wasm module under wasmtime** in the sandbox (via the
`run-command` Dock import / `CommandRegistry.run/3-5`), with **no native execution**. Two catalogs in
`Workbooks.Pallet` provide them; both are pure DATA on general mechanisms (adding a tool = a catalog
entry, not code).

## Lane A — prebuilt-WASI (`Pallet.@catalog`)
Fetched + sha-pinned + registered (no build). Seed with `Pallet.seed/0` — or set **`WB_PALLET=1`** to
auto-seed at boot (background, non-blocking). 18 commands:

| Command | What | Invoke |
|---|---|---|
| `python` | CPython 3.12 | `run("python", "", ["-c", "print(2**10)"])` |
| `ruby` | Ruby 3.2 | `run("ruby", "", ["-e", "puts 2**10"])` |
| `wasm3` | Wasm3 interpreter | `run("wasm3", "", ["--version"])` |
| `coreutils` | uutils multicall (~100 applets: ls/cat/wc/sort/head/seq/base64/sha256sum/…) | `run("coreutils", stdin, ["wc", "-l"])` |
| `sqlite3` | SQLite shell | `run("sqlite3", "SELECT 6*7;", [])` |
| `prolog` | Trealla Prolog | `run("prolog", "", ["-g", "X is 6*7, write(X), nl, halt"])` |
| `wat2wasm` `wasm2wat` `wasm-validate` `wasm-objdump` `wasm-strip` `wasm-decompile` `wasm-interp` `wasm-stats` `wasm2c` `wast2json` `wat-desugar` `spectest-interp` | WABT (12 tools) | `run("wat2wasm", "", ["--version"])` |

## Lane B — build-from-source (`Pallet.@csource`)
Built IN-SANDBOX (clang.wasm), content-addressed, then **persisted + reloaded at boot** (no rebuild).
Provision once with `Pallet.seed_csource/0` (slow — one clang build each). 7 commands:

| Command | What | Invoke |
|---|---|---|
| `lua` | Lua 5.4 | `run("lua", "", ["-e", "print(6*7)"])` |
| `duk` | Duktape (ES5/ES2015 JS) | `run("duk", "", ["-e", "6*7"])` |
| `wren` | Wren (class-based scripting) | `run("wren", "", ["-e", "System.print(6*7)"])` |
| `qjs` | QuickJS-ng (full ES2023 JS) | `run("qjs", "", ["-e", "6*7"])` |
| `gz` | gzip-compatible compression | `run("gz", data, [])` / `run("gz", comp, ["-d"])` |
| `lz4` | LZ4 frame compression | `run("lz4", data, [])` / `run("lz4", comp, ["-d"])` |
| `zstd` | Zstandard compression | `run("zstd", data, [])` / `run("zstd", comp, ["-d"])` |
| `br` | brotli web compression | `run("br", data, [])` / `run("br", comp, ["-d"])` |
| `qr` | text → ASCII QR code | `run("qr", "https://…", [])` |
| `b2` | BLAKE2b-512 hash → hex | `run("b2", data, [])` |
| `b3` | BLAKE3-256 hash → hex | `run("b3", data, [])` |
| `argon2` | Argon2id password hash → hex | `run("argon2", pw, [])` |
| `md` | CommonMark markdown → HTML | `run("md", "# Hi", [])` |

## Built-ins (always present)
`jq` (JSON), `grep` (regex line match), `upper` (demo), `wbox` (in-wasm shell coreutils). Plus the
compiler lanes (C/Zig/Rust/Go/JS/TS/Svelte → wasm) via `PackageManager`/`Compilers`.

## Adding a tool (the pattern)
- **Prebuilt WASI artifact** → append `{name, kind, url, sha, …}` to `Pallet.@catalog`.
- **Buildable C source** → append `{name, url, sha, build_opts}` to `Pallet.@csource` where
  `build_opts` ∈ `:src_subdir` | `:src_globs` (split dirs) | `:exclude` | `:extra_sources` (inject a
  minimal main) | `:cflags` (e.g. `-DWITH_MAIN`). The lane handles multi-file, headers, generated
  `.inc` companions, setjmp/longjmp, wasi-libc emulated features, host-escape stubs, unity builds.
- File I/O for any command: pass `dirs` (WASI `--dir` preopens) to `run/5`.

## Known gaps (filed)
- **wb-jsc4** — structure-preserving builds (tools with relative-parent `#include "../x.h"`, e.g. zstd).
- **wb-2ku.7** — fast Svelte/Vue compile (their JS compiler is interpreter-bound in QuickJS).
