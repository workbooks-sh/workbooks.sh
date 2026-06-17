# sandbox

The in-sandbox command set: scripting languages, JS engines, crypto, fonts & text-shaping, image, XML, regex, linear algebra, document conversion, and data formats — 30+ real upstream tools compiled to `wasm32-wasi` and run under wasmtime, with zero native execution. Each command *is* a sandboxed wasm module: stdin → stdout, argv passed through.

## When to reach for it

Reach for `sandbox` whenever an agent needs a real CLI capability inside the sandbox — SQL, `jq`, hashing, a Python or Ruby interpreter, image codecs, document conversion. Unlike `git`/`ffmpeg` this isn't one wrapped CLI; it's the *index* of the whole command set the agent can invoke by name. Pass file access with a WASI `--dir` preopen.

## Example

```
echo '{"a":1}' | jq '.a'
echo "SELECT 1+1;" | sqlite3
echo "# Title" | md                  # markdown → HTML
python script.py                      # full CPython on wasm
```

## What it grants

- Languages: `python`, `ruby`, `php`, `lua`, `wren`, `mujs`, `zforth`; JS engines `qjs` (ES2023) and `duk`.
- Compression (`gz`/`lz4`/`zstd`/`br`/`wuffs`), hashing (`b2`/`b3`/`argon2`), crypto (`sodium`/`mbedtls`/`openssl`).
- Data + docs: `sqlite3`, `jq`, `md`, `pandoc`, `yaml`, `tmpl`, `arrow`, `protobuf`.
- Fonts/text (`freetype`/`harfbuzz`), image (`jpeg`/`png`), XML (`expat`/`xml2`), regex (`onig`/`rgx`), math (`eigen`), plus `qr`, `tar`, `coreutils` (~100 applets), WABT wasm tooling, Prolog, Wasm3, and more.

## Maturity

Stable (v0.1.0). Built across five lanes in `Workbooks.Pallet` (prebuilt WASI, C/C++ from source via `clang.wasm`, Rust crates via mrustc→clang, pure-Python on CPython.wasm, npm/JS via esbuild + StarlingMonkey, with QuickJS as a fallback), seeded at boot then persisted and reloaded — no rebuild.
