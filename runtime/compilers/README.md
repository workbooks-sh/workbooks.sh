# compilers/ — language compilers compiled to WASM, run IN the sandbox

RELATED: [../docs/COMPILER-IN-WASM](../docs/COMPILER-IN-WASM.md)

Each subdir is ONE source language whose compiler we run inside the wasm sandbox
(zero native execution), so compiling UNTRUSTED source is as safe as running Python.
Sorted by the source language the compiler accepts.

- `c/`    — C   compiler → wasm   (tcc / chibicc; no LLVM; c4 proved the model)
- `zig/`  — Zig compiler → wasm   (self-hosted wasm backend; no LLVM)
- `rust/` — Rust compiler → wasm  (rustc + rustc_codegen_cranelift; no LLVM; + watt proc-macros)

Each dir holds: a pinned source spec, a build recipe/script (produces `<lang>c.wasm`),
any libc/syscall stubs, and a README with the plan + frontier risks. The shared
integration (run the compiler.wasm in-sandbox, preopen source+sysroot, capture the
emitted artifact, run it) is the `compiler:` framework in host/ (command_registry +
toolkits), NOT duplicated per language. Built artifacts are NOT committed (derived;
DeployKit builds them from these recipes). See [../docs/COMPILER-IN-WASM](../docs/COMPILER-IN-WASM.md).
