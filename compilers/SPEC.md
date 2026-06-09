# wasm-compile — the compiler-in-WASM framework spec

Compile **untrusted** source by running the **compiler itself inside a wasm sandbox**
(wasmtime), so compilation has **zero native execution** — the capability gate (WASI
preopens) is the only boundary. This makes compiling adversarial C/Zig as safe as running
an interpreter, unlike a native `cc`/`zig`/`rustc` under bwrap/seatbelt (an OS sandbox is
defense-in-depth, **not** an isolation boundary for adversarial native code).

## The contract

A toolchain is `compiler.wasm` (+ an optional sysroot dir). The framework:

```
compile(compiler.wasm, source, sysroot) --in wasmtime--> artifact   (zero native exec)
run(artifact, argv, stdin, dirs)         --in wasmtime-->            (already sandboxed)
```

Three toolchain **kinds**:

- **compile-and-run** — the compiler reads source and executes it in one wasm process
  (e.g. `c4`). No emitted artifact; the run is the same process.
- **compile-to-wasm** — the compiler emits a wasm artifact we then run (e.g. `clang`+`lld`).
- **compile-to-c-then-wasm** — the compiler emits C, which a `compile-to-wasm` toolchain
  then compiles+links (e.g. Zig: `zig1.wasm` → C → `clang`).

## Engine config

wasmtime, with: `-W exceptions=y` (setjmp/longjmp), `-W memory64=y` (>4 GB compiles),
`-W fuel=<n>` + `-W timeout=<ms>` (a runaway compile is trapped). A compiler gets far
higher fuel/timeout than a filter; the timeout bounds DoS, the preopens bound FS reach.

## The preopen / staging model

- The compiler sees **only** what you preopen: the (untrusted) source dir, the sysroot,
  a writable `/tmp` (`TMPDIR`). It cannot reach the host FS outside those.
- Some compilers (zig) resolve **every** path against a single preopen → stage a per-job
  dir beside the shared resources under one mount. Others (clang) accept multiple preopens.
- The clang **driver cannot spawn a subprocess** under WASI, so `compile` and `link` are
  **separate** in-sandbox invocations of the same multitool (`clang -c`, then `wasm-ld`).

## Bridges (compile-to-c-then-wasm)

Feeding one compiler's C output to clang/lld can need glue (all data-only, no trust impact):
- **wasi shim** — if the producer declares wasi syscalls as bare externs (zig does:
  `fd_write`, `proc_exit`, …), a generated shim forwards each to wasi-libc's `__wasi_*`
  import (full preview1 set, from `<wasi/wasip1.h>`).
- **builtin stubs** — no-op `__builtin_return_address`/`frame_address` (clang-on-wasm
  lacks them; stack-trace-only).
- **crt selection** — if the producer's object brings its own `_start`, link with no crt1.

## Registry

`toolchains/registry.json` pins each toolchain by `source.url` + `source.sha256` (or a
vendored source path) and points at its recipe. A toolchain is **working** (with proof) or
**blocked** (with a committed blocker note naming the precise upstream wall). No stubs.

## Security note

Built `*.wasm` are **derived** — never committed; recipes (sha-pinned) reproduce them.
A prebuilt is inert bytes until run, and the only trust gate before run is the sha pin;
at run time it is still capability-gated in the sandbox (defense in depth).
