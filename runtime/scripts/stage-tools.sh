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
for lane in rust clang zig go js c; do take "$lane/build.sh"; done

# --- rust: the 3 mrustc wasm + 1.74 libstd link objects + the wb runtime crate + std shims --------
take rust/mrustc-root/mrustc_std.wasm
take rust/mrustc-root/mrustc_pm.wasm
take rust/mrustc-root/mrustc.wasm
take rust/mrustc-root/mrustc/output-wasi-174        # prebuilt libstd (.o/.rlib/.hir) the linker needs
take rust/std                                        # setjmp-stub.h + cc/mrustc wrapper templates the pipeline copies
take rust/wb                                         # the BEAM-runtime crate (auto-provided as `use wb;`)
take rust/manifest.org

# --- clang: the LLVM-for-wasi driver + sysroot (mounted as /usr in the guest) -------------------
take clang/clang-root/llvm.core.wasm
take clang/clang-root/sysroot
# C++ EXCEPTIONS archives (new-EH libc++abi + libunwind) — gitignored build artifacts produced by
# clang/build.sh, staged INTO the sysroot. `take sysroot` above already copies them, but name them
# explicitly so a partial/manual stage still ships them (this is how artifacts ship — wb release canon).
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
take svelte               # the in-sandbox Svelte lane (sveltejob.js pre-bundle hook) — wb-2ku.5
take js/shims            # Node core + dock shims (events/buffer/fs/http/crypto/…) — wb-spy/wb-e1x
take js/manifest.org

# --- c: the C4 single-file compiler (compiled on demand in-sandbox) -----------------------------
take c/c4.c
take c/manifest.org

# --- wasm-tools recipe (the wasm-tools.wasm itself ships under build/, already in the image) ----
take wasm-tools/build.sh

echo "stage-tools: done — $(du -sh "$DST" | cut -f1) total" >&2
take esbuild/esbuild.wasm      # AOT bundler (wasip1) — the fast lane, replaces QuickJS bundlejob for JS/TS/JSX (wb-feto)
