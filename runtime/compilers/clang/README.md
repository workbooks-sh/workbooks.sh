# clang/lld compiler-in-WASM (compilers/clang/)

EPIC: wb-zyl

STATUS: DONE — full C/C++ compiled AND run in the sandbox, zero native execution

## What this is

The production full-C compiler-in-wasm: `YoWASP clang/lld 22.1.0` — LLVM built *for*
wasm32-wasi, so the compiler itself is a wasm module that runs on wasmtime and emits
wasm. Unlike c4 (an interpreted C *subset*) this is the real clang frontend + LLVM
codegen + lld, handling full C/C++. It is also the backend that finishes Zig
(zig1.wasm emits C → clang compiles+links it → wasm).

We do NOT build LLVM. There is no no-LLVM compiler that emits wasm (tcc/chibicc/cproc
emit native machine code; c4 interprets a subset), so a *full* C→wasm-in-wasm compiler
is necessarily clang/LLVM. Building LLVM→wasm32-wasi ourselves is the heavy frontier
(LLVM RFC #79073); instead we fetch + sha-pin YoWASP's prebuilt, which already targets
our exact engine (wasmtime). `build.sh` pulls the npm package (@yowasp/clang), verifies
the sha, and extracts `llvm.core.wasm` (the clang+lld multitool, ~75 MB) + its sysroot
(wasi-libc, headers, libclang_rt.builtins.a).

## How it runs (the two-stage in-sandbox pipeline)

`llvm.core.wasm` is one wasm32-wasi command (imports ONLY wasi_snapshot_preview1) that
dispatches on its first argv to act as clang or wasm-ld. The clang *driver* cannot spawn
a subprocess under WASI, so compile and link are SEPARATE invocations (YoWASP's JS driver
chains them; we do it explicitly in `Workbooks.Compilers.compile_c/3`):

1. `clang --target=wasm32-wasip1 --sysroot=/usr -O2 -c src.c -o out.o`
2. `wasm-ld -m wasm32 -L/usr/lib/... crt1-command.o out.o -lc libclang_rt.builtins.a -o out.wasm`

Mounts: the sysroot at `/usr` (clang's resource-dir + libc), a per-job dir at `/work`
(the untrusted source + outputs), and a writable `/tmp` (`TMPDIR`, clang temp files).
A compiler gets raised fuel/timeout; the timeout traps a runaway compile, the preopens
bound FS reach. `compile_and_run_c/3` then runs the emitted wasm — also in the sandbox.

## Proven

`Compilers.compile_and_run_c("hello.c")` → "10!=3628800": untrusted C compiled, linked,
and executed entirely in wasm, zero native execution. See `test/compilers_test.exs`
(`:build`). Also drives the Zig end-to-end chain (see [compilers/zig/README](../zig/README.md)).

## Build

`build.sh` fetches @yowasp/clang 22.0.0-git20542-10 (sha256 6230ea1a…), extracts
`clang-root/llvm.core.wasm` + `clang-root/sysroot/`. Derived artifacts are gitignored;
DeployKit rebuilds from this recipe.
