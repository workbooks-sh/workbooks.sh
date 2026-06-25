#!/usr/bin/env bash
# wasix-std-unix-rebuild.sh — §7 target_family=unix unlock (bd wb-dkwy)
#
# WHAT THIS DOES, AND WHY IT IS NOT AGENT WORK
# --------------------------------------------
# Crates like mio/hyper/crossterm/ratatui select their backend at COMPILE time via
# `#[cfg(unix)]`. The stock wasix toolchain reports `target_family = ["wasm"]` (verified:
# `rustc --target wasm32-wasmer-wasi --print cfg` → target_family="wasm", target_os="wasi",
# vendor="wasmer", rustc 1.90.0-dev, NO rust-src). So those crates compile their
# *non-unix* fallback (usually a `compile_error!` or a stub) and the build fails or the
# program is inert. Nothing in the Washy RUNTIME can change this — the decision was made by
# rustc before a single host import is reached. The ONLY lever is to rebuild the wasix-org
# Rust std so the target advertises `target_family = ["wasm", "unix"]` AND std's
# `std::os::unix` surface compiles for the wasi target. That requires the wasix-org/rust
# fork + the wasix-libc unix headers, an hours-long x.py build on a provisioned box. This
# script is the reproducible recipe to run THERE; it is deliberately a shell script (infra
# tooling for an external machine), not a `.work` workbook.
#
# RUNTIME READINESS IS ALREADY PROVEN. The four blocked crates need NO new host imports —
# their runtime surfaces are exercised today by real compiled C:
#   • crossterm/ratatui  → §4 tty   (unix_termios.c: termios raw-mode + TIOCGWINSZ)
#   • mio/hyper          → §3 socket (unix_tcp_server.c: socket/bind/listen/accept/echo)
# So once std advertises unix and links, the crates run on the EXISTING runtime. This is a
# compile-side unlock only.
#
# PREREQUISITES (provisioned compiler-build machine)
#   • The wasix-org/rust fork checked out at the toolchain commit (rustc 1.90.0-dev).
#   • wasix-libc sysroot with the unix headers (the same tree as SYS below).
#   • python3, ninja, cmake, a host C/C++ toolchain, ~40GB disk, several hours.
set -euo pipefail

: "${RUST_FORK:?set RUST_FORK=/path/to/wasix-org/rust checkout}"
: "${WASIX_SYSROOT:=/private/tmp/wasix-sysroot/wasix-sysroot/sysroot}"
TARGET="wasm32-wasmer-wasi"
TARGET_SPEC="${RUST_FORK}/compiler/rustc_target/src/spec/targets/${TARGET//-/_}.rs"

echo "==> [1/5] Patch the target spec: target_family += \"unix\""
# The target's TargetOptions sets `families: cvs!["wasm"]`. Add "unix" so `cfg(unix)` and
# `cfg(target_family="unix")` both fire. This is THE one-line semantic change; everything
# else is making std actually compile under it.
if grep -q 'families: cvs!\["wasm"\]' "$TARGET_SPEC"; then
  sed -i.bak 's/families: cvs!\["wasm"\]/families: cvs!["wasm", "unix"]/' "$TARGET_SPEC"
  echo "    patched $TARGET_SPEC"
else
  echo "    !! could not find 'families: cvs![\"wasm\"]' in $TARGET_SPEC"
  echo "    !! inspect the file — the wasi target options moved; add \"unix\" to its families list."
  exit 2
fi

echo "==> [2/5] Ensure std::os::unix compiles for wasi"
# std gates `pub mod unix` behind `cfg(unix)` in library/std/src/os/mod.rs. With the family
# patch it now tries to build, pulling in `sys/pal/unix`. wasi already has `sys/pal/wasi`;
# we DO NOT want the full unix PAL. The minimal viable surface most crates need is the
# `std::os::unix::io` (RawFd/AsRawFd/FromRawFd/OwnedFd) + `std::os::unix::ffi` traits, which
# are PAL-independent. Strategy: build a thin `os/unix` that re-exports the wasi fd types as
# the unix `RawFd` aliases, rather than the native unix PAL.
#
# This is the load-bearing engineering step and is fork-version-specific. Apply the overlay
# patch series in scripts/wasix-std-unix/*.patch (maintained alongside this script):
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/wasix-std-unix"
if [ -d "$PATCH_DIR" ]; then
  for p in "$PATCH_DIR"/*.patch; do
    [ -e "$p" ] || continue
    echo "    git apply $p"
    git -C "$RUST_FORK" apply --3way "$p"
  done
else
  echo "    NOTE: no overlay patches present at $PATCH_DIR."
  echo "    First run: build, read the std compile errors, and capture the minimal os::unix"
  echo "    re-export shim as patches here so the next run is one-shot. Expected errors are"
  echo "    'cannot find type RawFd in os::unix::io' and unix PAL references — satisfy them"
  echo "    with re-exports of the wasi fd types, NOT by pulling in sys/pal/unix."
fi

echo "==> [3/5] Build std for $TARGET"
( cd "$RUST_FORK" && \
  WASIX_SYSROOT="$WASIX_SYSROOT" \
  ./x.py build --target "$TARGET" library/std )

echo "==> [4/5] Link the rebuilt toolchain as 'wasix-unix'"
STAGE1="${RUST_FORK}/build/$(rustc -vV | sed -n 's/host: //p')/stage1"
rustup toolchain link wasix-unix "$STAGE1" || true
echo "    rustup toolchain 'wasix-unix' → $STAGE1"

echo "==> [5/5] Verify: target now advertises unix, and a mio program links"
RUSTUP_TOOLCHAIN=wasix-unix rustc --target "$TARGET" --print cfg | grep -E 'target_family|unix' || true
VERIFY_DIR="$(cd "$(dirname "$0")/../test/conformance/wasix/blocked" && pwd)"
echo "    building the pre-staged blocked-crate fixtures in $VERIFY_DIR ..."
( cd "$VERIFY_DIR" && \
  for crate in rust_mio rust_hyper rust_crossterm rust_ratatui; do
    echo "    --- $crate ---"
    RUSTUP_TOOLCHAIN=wasix-unix cargo build --release --target "$TARGET" \
      --bin "$crate" 2>&1 | tail -3 || echo "    !! $crate failed — capture the cfg gap"
  done )

cat <<'DONE'

==> DONE. If all four built, copy the artifacts into test/conformance/wasix/:
      cp target/wasm32-wasmer-wasi/release/rust_{mio,hyper,crossterm,ratatui}.wasm ../
    then add them to washy_wasix_c_test.exs (interp ≡ asm) and close bd wb-dkwy + the §8
    named-crate gate on wb-t5n9. The RUNTIME needs no change — §3/§4 already cover them.
DONE
