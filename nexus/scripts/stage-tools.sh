#!/usr/bin/env bash
# stage-tools.sh — assemble the LEAN, runtime-only slice of compilers/ for the deploy-kit.
#
# The provisioned compilers/ tree is ~6.6G, but >90% is BUILD SCRATCH (rustc source tarballs,
# the mrustc C++ build, wasi-sdk, 1.54 intermediates, .bak files) needed only to PRODUCE the
# in-sandbox wasm tools — never to RUN them. This copies only what the runtime reads at compile
# time, preserving the exact relative paths the pipeline resolves (default_root + the per-lane
# roots), so a deployed runtime (local container OR cloud image) compiles identically to dev.
#
# Result lands in compilers-dist/ (~600-650M). The Dockerfile COPYs it to /app/compilers.
# Idempotent. Usage: scripts/stage-tools.sh [SRC=compilers] [DST=compilers-dist]
set -euo pipefail

cd "$(dirname "$0")/.."                       # runtime/
SRC="${1:-compilers}"
DST="${2:-compilers-dist}"

[ -d "$SRC" ] || { echo "stage-tools: source '$SRC' not found (run provision first)" >&2; exit 1; }

# copy a path (file or dir) from SRC to DST, preserving the relative layout. Skips silently if
# the source is absent so a partially-provisioned tree still stages what it has.
take() {
  local rel="$1" s="$SRC/$1" d="$DST/$1"
  [ -e "$s" ] || { echo "  · skip (absent): $rel" >&2; return 0; }
  mkdir -p "$(dirname "$d")"
  cp -a "$s" "$d"
  echo "  + $rel ($(du -sh "$d" | cut -f1))"
}

echo "stage-tools: $SRC -> $DST (lean runtime slice)" >&2
rm -rf "$DST"
mkdir -p "$DST"

# Each lane's build.sh registers its CLI_BIN command at boot (CommandRegistry.build_and_register_script
# + the compile-path self-heal). They SHORT-CIRCUIT when the prebuilt wasm is already present (which it
# is, in this lean slice) — so this registers, it never rebuilds. Without build.sh: {:unknown_command}.
for lane in rust clang zig go js c swift; do take "$lane/build.sh"; done

# --- rust: the 3 mrustc wasm + 1.74 libstd link objects + the work runtime crate + std shims --------
take rust/mrustc-root/mrustc_std.wasm
take rust/mrustc-root/mrustc_pm.wasm
take rust/mrustc-root/mrustc.wasm
take rust/mrustc-root/mrustc/output-wasi-174        # prebuilt libstd (.o/.rlib/.hir) the linker needs
take rust/mrustc-root/mrustc/output-wasi-174-threads # SHARED-MEMORY THREADS libstd (.o/.rlib/.hir) — compile_rust_threads links against these
take rust/std                                        # setjmp-stub.h + cc/mrustc wrapper templates the pipeline copies
take rust/wb                                         # the BEAM-runtime crate (auto-provided as `use wb;`)
take rust/manifest.org

# --- clang: the LLVM-for-wasi driver + sysroot (mounted as /usr in the guest) -------------------
take clang/clang-root/llvm.core.wasm
take clang/clang-root/sysroot
# C++ EXCEPTIONS archives (new-EH libc++abi + libunwind) — gitignored build artifacts produced by
# clang/build.sh, staged INTO the sysroot. `take sysroot` above already copies them, but name them
# explicitly so a partial/manual stage still ships them (this is how artifacts ship — work release canon).
take clang/clang-root/sysroot/lib/wasm32-wasip1/libc++abi-eh.a
take clang/clang-root/sysroot/lib/wasm32-wasip1/libunwind-eh.a
take clang/manifest.org

# --- zig: stage1 compiler + std lib (the lane resolves paths under zig-root) --------------------
take zig/zig-root
take zig/wasi_shim.c
take zig/manifest.org

# --- go: the yaegi interpreter (untrusted Go runs entirely inside it) ---------------------------
take go/yaegi-root
take go/manifest.org

# --- js / ts: QuickJS-ng runner + the tsc bundle + the npm lane (bundler, shims, dock harness) --
take js/qjs-run.wasm
take js/ts
take js/qjs-root
take js/harness.o
take js/harness_dock.o   # JsDock harness (env.* host caps → Javy.Net/Javy.VFS) — wb-e1x
take js/bundle           # the in-sandbox npm bundler (bundlejob.js) — without it bundle_dir fails
# The JS-family lane bundles (svelte compiler, solid babel transform, python interpreter) are
# gitignored — produce them on-demand via each lane's build.sh (fetch + bun/esbuild; no-op when
# already built), then stage. CI (.github/workflows/compilers-js.yml) runs the SAME scripts on a
# clean runner, so the bundles are present whether staged on a provisioned machine or in CI.
for lane in svelte solid python; do
  [ -f "$SRC/$lane/build.sh" ] && bash "$SRC/$lane/build.sh" >/dev/null 2>&1 || true
done
take svelte               # the in-sandbox Svelte lane (svelte_compile.js + vendor/compiler.cjs)
take solid                # the Solid lane (solid_compile.js removed; vendor/babel.js runs on StarlingMonkey)
take python/pythonrun.wasm # the Python lane interpreter (CPython 3.12 wasm32-wasi) — yaegi-style interpreter-in-wasm
take js/shims            # Node core + dock shims (events/buffer/fs/http/crypto/…) — wb-spy/wb-e1x
take js/manifest.org

# --- c: the C4 single-file compiler (compiled on demand in-sandbox) -----------------------------
take c/c4.c
take c/manifest.org

# --- swift: official Swift 6.2 toolchain + the Swift SDK for WebAssembly (WASI) ------------------
# Provisioned by swift/build.sh (fetches the swift.org toolchain + wasm SDK; gitignored, hours-cold).
# NOTE: swiftc is NATIVE (no wasm-hosted Swift compiler upstream yet) — host-side cross-compile; the
# PRODUCED artifact is still a sandboxed wasm component. Nexus.Compilers.Swift resolves under swift-root.
take swift/swift-root/usr
take swift/swift-root/swift-wasi.sdk
take swift/manifest.org

# --- wasm-tools recipe (the wasm-tools.wasm itself ships under build/, already in the image) ----
take wasm-tools/build.sh

# esbuild.wasm is gitignored (20MB) — produce it on-demand via its build.sh (needs native Go, ~8s;
# no-op when already built, or in a Go-less tree where it must already be present), then stage. (wb-feto)
[ -f "$SRC/esbuild/esbuild.wasm" ] || bash "$SRC/esbuild/build.sh" >/dev/null 2>&1 || true
take esbuild/esbuild.wasm      # AOT bundler (wasip1) — the fast lane, replaces QuickJS bundlejob for JS/TS/JSX
take esbuild/build.sh          # the recipe, so the dist slice can self-heal/rebuild it too

# --- AGGRESSIVE PRUNE (opt-in: STAGE_PRUNE=1) ----------------------------------
# Two removals that the RUNTIME compile paths were traced not to read, but which
# need a provisioned-machine smoke test to confirm before becoming default. Each
# is OFF by default so a normal `stage-tools.sh` run ships the proven-safe slice.
#
# VERIFY (on a provisioned machine, after STAGE_PRUNE=1 stage-tools.sh):
#   cd runtime
#   # Rust on-demand compile (links libstd from *.rlib.o, never the *.rlib.c):
#   mix run --no-start -e 'IO.inspect(Workbooks.Compilers.rust_compile_to_wasm("test/fixtures/hello.rs"))' \
#     -e 'or any rust eval case' ; mix test --only build   # rust/zig compile suites
#   # Zig on-demand compile (target wasm32-wasi only):
#   mix run --no-start -e 'IO.inspect(Workbooks.Compilers.compile("zig", "<a .zig>"))'
# If both still produce a runnable .wasm, fold these into the default staging.
if [ "${STAGE_PRUNE:-0}" = "1" ]; then
  echo "stage-tools: AGGRESSIVE PRUNE on (STAGE_PRUNE=1)" >&2

  # (1) mrustc transpiled-C INTERMEDIATES for the PREBUILT libstd crates (~88 MB).
  # Traced: the runtime Rust link globs output-wasi-174/*.rlib.o (compilers.ex:730)
  # and guards on libstd.rlib.o (L601) — it NEVER reads the std crates' *.rlib.c
  # (that C was already compiled to *.rlib.o at provision time). Dep-crate .rlib.c
  # are regenerated per-compile by mrustc (L1137 File.rm + emit), so dropping the
  # SHIPPED std *.rlib.c does not affect them. Keep wbrt.rlib.c? No — it too is
  # regenerated at runtime (compilers.ex:1478). So drop ALL *.rlib.c here.
  for od in output-wasi-174 output-wasi-174-threads; do
    d="$DST/rust/mrustc-root/mrustc/$od"
    [ -d "$d" ] || continue
    before=$(du -sk "$d" | cut -f1)
    find "$d" -maxdepth 1 -name '*.rlib.c' -delete
    after=$(du -sk "$d" | cut -f1)
    echo "  - pruned $od/*.rlib.c: $(( (before-after)/1024 )) MB" >&2
  done

  # (2) zig libc headers/sources for NON-wasi targets (~150 MB). The zig lane only
  # ever compiles `-target wasm32-wasi` (compilers.ex:82,108) against --zig-lib-dir
  # zig-root/lib. wasm needs lib/libc/{wasi, include/{wasm-wasi-musl, generic-musl,
  # any-* fallbacks}} + lib/libc/musl. The per-OS trees (windows/freebsd/netbsd/
  # openbsd/darwin/glibc/mingw) and their include/ arch dirs are dead for wasi.
  # CONSERVATIVE set kept; everything else dropped. If a wasi compile breaks on a
  # missing header, widen the keep-list rather than reverting.
  zl="$DST/zig/zig-root/lib/libc"
  if [ -d "$zl" ]; then
    before=$(du -sk "$zl" | cut -f1)
    # drop whole per-OS libc trees not used by wasm32-wasi
    for os in mingw glibc darwin netbsd freebsd openbsd; do rm -rf "$zl/$os"; done
    # drop non-wasi/non-musl include arch dirs (keep wasm/musl + any-* generic fallbacks)
    if [ -d "$zl/include" ]; then
      find "$zl/include" -mindepth 1 -maxdepth 1 -type d \
        ! -name 'wasm-wasi-musl' ! -name 'generic-musl' ! -name 'any-linux-any' \
        ! -name 'any-darwin-any' -exec rm -rf {} +
    fi
    after=$(du -sk "$zl" | cut -f1)
    echo "  - pruned zig libc non-wasi: $(( (before-after)/1024 )) MB" >&2
  fi
fi

echo "stage-tools: done — $(du -sh "$DST" | cut -f1) total" >&2
