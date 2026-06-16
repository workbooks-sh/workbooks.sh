
# Language lanes

> Author a toolkit in any of five WASM languages — compiled in the sandbox.

You write a toolkit in the language you already use. The runtime compiles it to
WASM **inside its own sandbox** — the compiler is itself WASM, so there's no
toolchain on your machine and untrusted source never touches a native compiler.

| lane | notes |
| --- | --- |
| JS | via Javy; the fastest lane to a first build |
| C | clang in-sandbox; full stdio |
| Go | via a yaegi interpreter; stdlib |
| Rust | mrustc → clang, full std; slower, cached |
| Zig | compute today (stdio commands are a known gap) |

For a self-authored command you point `build-inline` at a source file; for a
durable toolkit the manifest's `#+BUILD_LANG` and `#+BUILD_SRC` drive the build.

```bash
wb toolkit build-inline rev rust ./reverse.rs
```

- Build + register + run in one step: [Self-authoring & hot-swap](self-authoring.md)
