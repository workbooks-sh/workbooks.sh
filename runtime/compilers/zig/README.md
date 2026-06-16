# Zig compiler-in-WASM (compilers/zig/)

EPIC: wb-zyl (P2)

STATUS: DONE — untrusted .zig compiled AND run entirely in the sandbox (via the clang lane)

## END-TO-END (the run step is now closed)

`Workbooks.Compilers.zig_compile_and_run/4` runs the full pipeline in wasm, zero native
execution: zig1.wasm (.zig→C) → clang.wasm (C + the wasi shim → object) → wasm-ld
(link→wasm) → run. Proven: a `std.debug.print` program → "zig-e2e=42"
(test/compilers_test.exs, `:build`).

Two bridges were needed to feed zig's C-backend output to clang/lld (both committed):
- `wasi_shim.c` — zig declares wasi syscalls as bare externs (`fd_write`, `proc_exit`,
  …) with no import attributes; the shim forwards each to wasi-libc's `__wasi_*` import
  (auto-generated from <wasi/wasip1.h>, full preview1 set). Linked with the zig object.
- a prelude no-ops `__builtin_return_address/frame_address` (zig emits these for
  stack-trace capture; clang-on-wasm doesn't implement them — debug-only, safe to stub).
- link with `crt: false`: zig's object brings its own `_start` + libc init, so we omit
  clang's crt1-command.o to avoid a duplicate `_start`.

(Direct .zig→wasm in-sandbox — zig's self-hosted wasm backend running in wasm — remains
blocked upstream, ziglang/zig#20665; the C-backend route above is the working path.)

---

Original notes (compile-to-C half):

## What works (proven through our runtime)

`zig1.wasm` — the zig 0.16.0 *bootstrap compiler* — runs the WHOLE zig frontend
(parse + AstGen + Sema) plus the *C-backend codegen* ENTIRELY in the wasm sandbox,
with *zero native execution*, and emits C. We drive it through the same path as every
other command (`CommandRegistry.run` → `PackageManager.run` → wasmtime), so untrusted
`.zig` is compiled with no native compiler ever touching it.

Verified: `Workbooks.Compilers.compile("zig", "hello.zig")` → ~800 KB of genuine zig
C-backend output (`#include "zig.h"`, `zig_static_assert` size checks) for a
`std.debug.print` program. See `test/compilers_test.exs` (`:build` tag).

This is the security-critical milestone for Zig: *the compiler itself is the sandboxed
artifact*, so compiling adversarial Zig is as safe as running an interpreter — unlike a
native `zig build` under bwrap/seatbelt, which is NOT an untrusted-source boundary.

## How it runs (the one-preopen constraint)

Under generic wasmtime, zig resolves EVERY path against a single preopen. So `build.sh`
extracts the source tree to `zig-root/` (giving `stage1/zig1.wasm` + `lib/`), and
`Compilers.compile/4` stages a per-job dir beside `lib/` under that one root, preopens
the root, and invokes:

```
zig1 build-obj -ofmt=c -OReleaseSmall --zig-lib-dir lib \
     --cache-dir jobs/<id>/zc --global-cache-dir jobs/<id>/gc \
     --name out -femit-bin=jobs/<id>/out.c -target wasm32-wasi -Mroot=jobs/<id>/src.zig
```

The job dir (untrusted source + caches) is removed after each compile. A compiler gets
raised fuel/timeout (a real compile far outweighs a filter); the timeout traps a
runaway compile and the preopen bounds FS reach.

## The honest end-to-end-run status (what's NOT done here)

- *Direct .zig → wasm in-sandbox* is blocked upstream: building the zig compiler with
  its self-hosted *wasm backend* to `wasm32-wasi` (so a wasm-hosted zig emits wasm
  directly) is ziglang/zig#20665 — OPEN. Blockers: `os.realpath` is unavailable on
  WASI, and the self-hosted wasm backend still has codegen bugs (e.g. #25888,
  corrupted data segments). zig1.wasm itself is bootstrap-only: ALL backends except
  the C backend are disabled, and `ar`/linker commands are stubbed out (`build-exe`
  panics on `ar_command`), so it can only `build-obj -ofmt=c`.
- *Therefore end-to-end "compile + run .zig in the sandbox"* = this C emission +
  the C lane: take `out.c` through a full C-compiler-in-wasm (tcc.wasm) → wasm → run.
  That final step is exactly what P1 productionizes for C (c4 is a C SUBSET and will
  not accept zig's C-backend output, which needs full C99 + a libc + compiler_rt). So
  Zig's runnable artifact lands when tcc.wasm lands; the compiler-in-sandbox half — the
  hard, novel half — is done and proven here.

## Build

`build.sh` fetches the pinned zig 0.16.0 source tarball (sha256
43186959…1bfdf), verifies it, and extracts `zig-root/`. Derived artifacts
(`zig-root/`, the tarball) are gitignored — DeployKit rebuilds from this recipe.
