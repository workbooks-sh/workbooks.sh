# palette — Zig

# The honest Zig story (engine = wasmtime only; see [runtime-engine-wasmtime-only](runtime-engine-wasmtime-only))

  Zig is a COMPILE-TO-WASM authoring language, NOT a sandboxed interpreter. There is
  no "zig run arbitrary .zig" inside the sandbox — running the Zig COMPILER on
  wasmtime is the LLVM-class mountain (same tier as Rust; zig1.wasm is only a
  bootstrap that emits C, not a general compiler). So Zig's place in the palette is
  the same as C: author a tool in Zig, compile it to a wasm command, run it sandboxed.

# Author a command in Zig (the zigbuild path)

  Drop a `.zig` next to a `runtimes/<name>/manifest.org` with
  `#+BUILD_SRC: zigbuild:<file.zig>`. Then:

## native zig compiles the source → wasm32-wasi → registered command
```bash
  work kit build palette zig
```

  Proven: the bundled demo compiles to a command and runs through our runtime,
  printing `zig command via our runtime: 55`. (Native zig is the build tool, like
  wasi-sdk for C; the OUTPUT runs on our wasmtime.)

# What's NOT here
  - No zig interpreter (compile-to-wasm only).
  - zig-compiler-in-wasm (run arbitrary .zig sandboxed) = the LLVM mountain — deferred,
    like rustc-in-wasm.
