
# Compilers

> Every compiler lane that turns source into a WASM command inside the sandbox — language, mechanism, status, limits.

The _compiler-in-WASM_ framework runs each language's compiler ITSELF as a wasm
module on wasmtime, so untrusted source compiles and runs with zero native
execution — as safe as running an interpreter. A native compile under bwrap is
NOT an untrusted-source boundary; this is.

Each lane lives in `runtime/compilers/<lang>/` as a build recipe plus a
`manifest.org`. The shared host driver is `Workbooks.Compilers`; it reuses the
command path (`CommandRegistry` + `PackageManager.run`, which enables
`-W exceptions` + memory64). Built compiler artifacts are NOT committed (derived;
DeployKit rebuilds from each recipe).

- **SRC:** runtime/host/compilers.ex#moduledoc

  :MATURITY: ships-today
  :EVIDENCE: runtime/host/compilers.ex:1-17

## Lane matrix

Status is per the THREE WALLS honesty tiers. "compile-and-run in-sandbox" means
the named test runs untrusted source through the wasm compiler and executes the
result, zero native execution.

| lane | accepts | mechanism | kind | status |
| --- | --- | --- | --- | --- |
| `c` | C (subset) | c4 interpreter (rswier/c4) → wasm | compile-and-run | ships-today |
| `clang` | C / C++ | YoWASP clang/lld 22.1.0 (LLVM-for-wasm32-wasi) | compile-to-wasm | ships-today |
| `zig` | Zig | zig1.wasm (→C) → clang lane → wasm | compile-to-c→wasm | ships-today |
| `rust` | Rust (no_std) | mrustc.wasm (→C) → clang lane → wasm | compile-to-c→wasm | partial |
| `go` | Go (stdlib) | yaegi-run.wasm interpreter (untrusted Go at runtime) | interpret-in-sandbox | partial |
| `js` | JavaScript | QuickJS-ng → wasm objects + wb harness | compile-to-wasm | ships-today |
| `esbuild` | JS/TS/JSX/TSX | esbuild (Go) → wasip1, JIT'd by wasmtime | bundle/transform | ships-today |
| `svelte` | Svelte 4 comp. | svelte/compiler in QuickJS → esbuild/bundlejob | bundle | partial |

  :MATURITY: ships-today
  :EVIDENCE: runtime/host/compilers.ex:494-2050

## Host driver — public API

Each lane is reached through `Workbooks.Compilers`. Signatures verbatim from
source; do not paraphrase.

| function | does |
| --- | --- |
| `list(root)` | languages with a `compilers/<lang>/manifest.org` |
| `build(lang, root)` | build the lane's compiler → registered wasm command |
| `compile_run(lang, src, argv, root)` | compile-and-run lane (c4): read + execute source |
| `compile(lang, src, opts, root)` | compile-to-C lane (zig): emit C, zero native exec |
| `compile_c(src, opts, root)` | C → object → wasm (clang lane) |
| `compile_and_run_c(src, run_argv, opts, root)` | compile C then run the emitted wasm |
| `compile_cpp(src, opts, root)` | C++ (`-std=c++17` default; exceptions opt-in) |
| `compile_threads(src, opts, root)` | C → shared-memory multithreaded wasm (real pthreads) |
| `zig_compile_to_wasm(src, opts, root)` | Zig → wasm via the C-backend + clang lane |
| `zig_compile_and_run(src, run_argv, opts, root)` | Zig full pipeline → run |
| `rust_compile_to_wasm(src, opts, root)` | Rust → wasm via mrustc → clang lane |
| `compile_rust_threads(src, opts, root)` | Rust → multithreaded wasm (atomics) |
| `js_compile_to_wasm(src, opts, root)` | JS → standalone wasm (QuickJS + harness) |
| `bundle_dir(dir, entry, opts, root)` | multi-file JS bundle (QuickJS bundlejob) |
| `esbuild_bundle_dir(dir, entry, opts, root)` | multi-file JS/TS/JSX bundle (esbuild) |
| `svelte_bundle_dir(dir, entry, opts, root)` | compile + bundle a Svelte project |

- **SRC:** runtime/host/compilers.ex#public-api

  :MATURITY: ships-today
  :EVIDENCE: runtime/host/compilers.ex:60-2050

# C lane (`c`)

c4 (rswier/c4) — a real self-hosting C-_subset_ compiler+VM with its own codegen
(no LLVM), patched for WASI. The c4 spike proved the compiler-in-sandbox model:
untrusted `.c` compiles and runs with zero native execution.

Limits: c4 accepts a C SUBSET only — it will not accept full C99, a libc, or
zig's C-backend output (that's the `clang` lane's job).

- **SRC:** runtime/compilers/c/manifest.org#COMPILER

  :MATURITY: ships-today
  :EVIDENCE: runtime/compilers/c/manifest.org:1-6

# C / C++ lane (`clang`)

The production full-C/C++ compiler-in-wasm: `YoWASP clang/lld 22.1.0` — LLVM
built _for_ wasm32-wasi, so the compiler is itself a wasm module on wasmtime that
emits wasm. Real clang frontend + LLVM codegen + lld. We do NOT build LLVM; we
fetch + sha-pin YoWASP's prebuilt (`@yowasp/clang` 22.0.0-git20542-10, sha256
6230ea1a…) and extract `llvm.core.wasm` (~75 MB) plus its wasi sysroot.

Because the clang driver cannot spawn a subprocess under WASI, compile and link
are SEPARATE invocations the host chains explicitly:

  1. `clang --target=wasm32-wasip1 --sysroot=/usr -O2 -c src.c -o out.o`
  2. `wasm-ld -m wasm32 -L… crt1-command.o out.o -lc libclang_rt.builtins.a -o out.wasm`

Proven: `compile_and_run_c("hello.c")` → "10!=3628800". This lane is also the
backend that finishes the Zig and Rust lanes (their C output → clang → wasm).

- **SRC:** runtime/compilers/clang/manifest.org#COMPILER

  :MATURITY: ships-today
  :EVIDENCE: runtime/compilers/clang/README.org:36-41

## C++

`compile_cpp/3` defaults `-std=c++17`, `-fno-exceptions` (links `-lc++`
`-lc++abi`); pass `exceptions: true` for the EH variant.

  :MATURITY: ships-today
  :EVIDENCE: runtime/host/compilers.ex:220-235

## Threads (shared-memory C)

`compile_threads/3` targets the `wasm32-wasi-threads` sysroot, builds `-pthread`,
links `--shared-memory --import-memory --export-memory --max-memory` + `-lpthread`.
The wasm imports `wasi:thread-spawn` and a shared memory; run via
`PackageManager.run(..., threads: true)`.

  :MATURITY: ships-today
  :EVIDENCE: runtime/host/compilers.ex:238-270
  :CAVEAT: requires the wasm32-wasi-threads sysroot staged in the image.

# Zig lane (`zig`)

`zig1.wasm` — the Zig 0.16.0 _bootstrap_ compiler — runs the WHOLE Zig frontend
(parse + AstGen + Sema) plus the C-backend codegen entirely in wasm, zero native
execution, and emits C. `zig_compile_and_run/4` then drives the full pipeline:
zig1.wasm (.zig→C) → clang lane (C + a wasi shim → object) → wasm-ld → run.
Proven: a `std.debug.print` program → "zig-e2e=42".

Two committed bridges feed zig's C output to clang/lld: `wasi_shim.c` forwards
zig's bare wasi externs to wasi-libc's `__wasi_*` imports, and a prelude no-ops
`__builtin_return_address/frame_address`. Linked with `crt: false` (zig brings
its own `_start`).

- **SRC:** runtime/compilers/zig/manifest.org#COMPILER

  :MATURITY: ships-today
  :EVIDENCE: runtime/compilers/zig/README.org:6-11

## Limit — no direct .zig → wasm in-sandbox

A wasm-hosted zig that emits wasm _directly_ (self-hosted wasm backend) is
blocked upstream (ziglang/zig#20665, OPEN): `os.realpath` is unavailable on WASI
and the self-hosted wasm backend has codegen bugs. zig1.wasm is bootstrap-only —
all backends except the C backend are disabled. The C-backend route above is the
working path; direct emission is not available.

  :MATURITY: wall
  :WALL: forge

# Rust lane (`rust`)

mrustc (thepowersgang/mrustc @ be69c747) — a from-scratch C++ Rust→C compiler —
built to wasm32-wasi so it runs in-sandbox; its C output goes through the clang
lane → wasm. `e2e.sh` proves "RUST IN WASM SANDBOX: 55" (fib(10)), zero native
execution: mrustc.wasm → clang.wasm → wasm-ld → run, every stage under wasmtime.
Real Rust (rustc-core crate + a user crate), targeting ~Rust 1.74.

- **SRC:** runtime/compilers/rust/manifest.org#COMPILER

  :MATURITY: partial
  :EVIDENCE: runtime/compilers/rust/README.org:6-14
  :CAVEAT: no_std is fully untrusted-in-sandbox; std uses a TRUSTED prebuilt libstd. Untrusted-std-in-sandbox needs a mechanical mrustc.wasm rebuild (std/mrustc-wasm-std.patch). Language ceiling ~mrustc 1.74 (edition 2024 / newest syntax rejected).

## What works / what doesn't

Verified on real crates.io crates: leaf + multi-file pure-Rust crates, hyphenated
names, transitive deps; declarative macros (bitflags, lazy_static, cfg-if);
feature-gated deps; proc-macro DERIVES executed in-sandbox (serde, derive-new)
auto-routed through the BEAM; full std (alloc/collections/fmt/io over a wasi
shim); i128 (emulated).

| limitation | symptom / mitigation | BEAM-offload |
| --- | --- | --- |
| language ceiling ~1.74 | "Unexpected token" → pin an OLDER crate version | no |
| no build-script codegen | build.rs that generates code → pin/vendor | yes (wb-iht) |
| version-resolution window | only-compilable version too old → pin explicitly | no (wb-rxi) |
| proc-macro re-exports | `use serde::Serialize` fails → import from `serde_derive` | no (wb-5bv) |
| no threads / 64-bit atomics | rayon/threaded tokio → single-threaded code | partial |
| no raw IO / net at runtime | std::net/fs → use Dock host capabilities | yes (wb-1mv) |

Every `rust_compile_to_wasm` failure is classified;
`Workbooks.Compilers.RustCaps.diagnose/1` returns
`%{category, summary, mitigation}`.

- **SRC:** runtime/compilers/rust/CAPABILITIES.org#what-works

  :MATURITY: partial
  :EVIDENCE: runtime/compilers/rust/CAPABILITIES.org:14-57

## Threads (Rust)

`compile_rust_threads/3` emits a multithreaded wasm (`--cfg target_feature=atomics`);
a 4-thread test is green.

  :MATURITY: partial
  :EVIDENCE: runtime/host/compilers.ex:794
  :CAVEAT: proven via target_feature=atomics without a mrustc fork; wired but not yet a general crate path.

## No in-sandbox rustc

Running upstream `rustc` itself in wasm is an open frontier: rustc embeds LLVM as
a library and shells out to a proc-macro server + linker as subprocesses
(impossible under WASI). No prebuilt `rustc.wasm` exists; cg_clif emits native
code, not wasm. The mrustc→C→clang chain above is the working substitute.

  :MATURITY: wall
  :WALL: forge

# Go lane (`go`)

yaegi (traefik/yaegi) — a pure-Go interpreter — cross-compiled to wasm32-wasip1
by the NATIVE Go toolchain (trusted one-time provisioning, like clang.wasm /
mrustc.wasm). At runtime `yaegi-run.wasm` INTERPRETS untrusted Go entirely in the
sandbox; the native compiler never touches user code. The PackageManager embeds
the user source as a `wbgosrc` custom section → a unique, content-addressable,
self-contained wasm.

- **SRC:** runtime/compilers/go/manifest.org#COMPILER

  :MATURITY: partial
  :EVIDENCE: runtime/compilers/go/manifest.org:1-12
  :CAVEAT: stdlib only — no external module deps; single main package.

# JavaScript lane (`js`)

QuickJS-ng (v0.10.0) compiled to wasm objects via the clang lane + the wb harness
(`harness.c`: Javy.IO + console + TextEncoder/Decoder). Untrusted JS embeds into
`js_src.c` and links against these objects → a standalone wasm. Zero native
execution; no native javy. The Javy.IO contract is preserved (reverse/uppercase
filters pass).

- **SRC:** runtime/compilers/js/manifest.org#COMPILER

  :MATURITY: ships-today
  :EVIDENCE: runtime/compilers/js/manifest.org:1-9

## Bundling — esbuild lane

esbuild (Go) compiled to wasip1, run under wasmtime (which JITs it to native).
Replaces the QuickJS-interpreted bundlejob for JS/TS/JSX: a multi-file bundle
that took ~23 min interpreting in QuickJS runs in ~160 ms here. Handles
JSX/TSX, TS, minify, bundle, tree-shake. The universal bundler under the
component compilers and the keystone for the frontend lanes (React / Preact /
Solid / vanilla / TS). `esbuild_bundle_dir/4`.

- **SRC:** runtime/compilers/esbuild/manifest.org#esbuild

  :MATURITY: ships-today
  :EVIDENCE: runtime/compilers/esbuild/manifest.org:1-17

# Svelte lane (`svelte`)

The Svelte component compiler run in-sandbox: `sveltejob.js` is concatenated
before the JS bundlejob and fed to `qjs-run.wasm` via the Javy.IO stdin→stdout
contract. It requires `svelte/compiler` from the project's hoisted node_modules
(the npm lane), runs `svelte.compile()` on each `.svelte` source (css injected →
one bundle), then reuses bundlejob's resolver + `bundle()`. Zero native execution
— no node/bun/vite/rollup. Driver: `svelte_bundle_dir/4`.

- **SRC:** runtime/compilers/svelte/manifest.org#COMPILER

  :MATURITY: partial
  :EVIDENCE: runtime/compilers/svelte/manifest.org:1-9
  :CAVEAT: Svelte 4 only; needs svelte/compiler in the project's hoisted node_modules.

# See also

- [The Dock & capabilities](../concepts/the-dock.md) — what a compiled command may reach at runtime.
- [Dock capabilities](./caps.md) — the runtime capability surface.
- `runtime/docs/COMPILER-IN-WASM.org` — the framework rationale ("why native compiles aren't a boundary").
- `runtime/compilers/rust/CAPABILITIES.org` — the full honest Rust contract.
