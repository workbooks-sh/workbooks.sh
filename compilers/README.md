# wasm-compile

**Compile untrusted source with the compiler running *inside* a WebAssembly sandbox —
zero native execution.** Any `wasmtime` host can compile and run adversarial C/Zig safely:
the compiler is itself a wasm module, gated by WASI capabilities, so a malicious program
gets nothing the sandbox doesn't grant — no matter what it does at compile time.

This is the standalone packaging of the compiler-in-WASM work: a [spec](SPEC.md), a pinned
[toolchains registry](toolchains/registry.json), and reproducible recipes.

## Status

| Language | In-sandbox compile + run | How |
|----------|--------------------------|-----|
| **C** (subset) | ✅ | `c4` — no-LLVM compiler+interpreter in one wasm process |
| **C** (full)   | ✅ | `clang`+`lld` (LLVM built for wasm32-wasi) → wasm |
| **Zig**        | ✅ | `zig1.wasm` (.zig→C) → `clang` (C→wasm) → run |
| **Rust**       | 🧱 blocked | rustc-in-wasm is an open upstream frontier — see the [blocker](../runtime/compilers/rust/README.org) |

Every entry is **working with a proof** or a **committed blocker note** naming the precise
upstream wall — no stubs.

## Quickstart (standalone, pure wasmtime — no Elixir)

```sh
# provision the clang toolchain (fetch + sha-verify the pinned YoWASP LLVM-for-wasi build)
bash ../runtime/compilers/clang/build.sh        # -> clang-root/llvm.core.wasm + sysroot

# compile + run untrusted C entirely in the sandbox
bash examples/run-c.sh hello.c                   # -> compiles, links, runs hello.wasm
```

See [`examples/run-c.sh`](examples/run-c.sh) for the exact two-stage wasmtime invocation
(`clang -c` then `wasm-ld`, then run the emitted wasm).

## Layout

- [`SPEC.md`](SPEC.md) — the framework contract, engine config, preopen/staging model, bridges.
- [`toolchains/registry.json`](toolchains/registry.json) — pinned toolchains (version, sha, source, recipe, status).
- `examples/` — standalone reference runners.
- `vendor.sh` — assemble a fully self-contained copy (registry + recipes + vendored source) for publishing.

Recipes are canonical in `runtime/compilers/<lang>/` (build.sh + manifest, tested in the
runtime). `vendor.sh` copies them here so this directory can ship as its own repo.

## License

Dual-licensed under [Apache-2.0](LICENSE-APACHE) OR [MIT](LICENSE-MIT), at your option.
Bundled toolchains keep their own licenses (see `registry.json` → `source.license`).
