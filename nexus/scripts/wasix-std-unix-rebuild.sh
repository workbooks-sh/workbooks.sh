#!/usr/bin/env bash
# wasix-std-unix-rebuild.sh — §7 target_family=unix unlock (bd wb-dkwy)
#
# ⬛ BREAKTHROUGH (2026-06-25): this needs NO fly machine and NO full rustc bootstrap. ⬛
# It is a LOCAL `-Z build-std` against the EXACT toolchain source commit, plus a bounded patch to the
# wasix `libc` Rust crate. The earlier "blocked 6 ways / provisioned machine" framing is superseded.
#
# WHY crates like mio/hyper/crossterm/ratatui don't compile
#   They gate their backends on `#[cfg(unix)]`. The stock wasix toolchain advertises
#   `target_family = ["wasm"]`, so `cfg(unix)` is false and the unix backend is never selected.
#   IMPORTANT: the std side is ALREADY DONE — `library/std/src/os/mod.rs` re-exports the wasix os
#   module AS `std::os::unix` for `target_os="wasi", vendor="wasmer"`. Only the family flag is missing.
#
# THE EXACT SOURCE (do not guess — the installed toolchain reports commit-hash "unknown")
#   The cargo-wasix toolchain `aarch64-apple-darwin_vYYYY-MM-DD.N+rust-1.90` is built from a wasix-org/rust
#   *release tag* of the same name. Resolve the tag → commit and clone THAT (a branch HEAD will NOT match
#   the installed rustc and std/core fail to compile with `meta_sized`/`platform-intrinsic` errors):
#     TAG="v2026-05-21.1+rust-1.90"                       # == basename of `rustc --print sysroot`'s toolchain
#     git clone --depth 1 --branch "$TAG" https://github.com/wasix-org/rust.git rustsrc
#     # rust 1.90 layout: library/Cargo.{toml,lock} are NATIVE; stdarch is VENDORED in-repo (NOT a submodule);
#     # only `library/backtrace` is a real submodule:
#     git -C rustsrc submodule update --init --depth 1 library/backtrace
#
# THE BUILD (local, ~10-15 min, small disk — std only, no compiler bootstrap)
#   1. Wire rustsrc as the toolchain's rust-src:
#        SYS="$(RUSTUP_TOOLCHAIN=wasix rustc --print sysroot)"     # cargo-wasix toolchain root
#        ln -s "$PWD/rustsrc"/{library,src,Cargo.toml,Cargo.lock} "$SYS/lib/rustlib/src/rust/"
#   2. Custom target spec = the built-in spec + "unix" in target-family (exact match otherwise):
#        rustc --target wasm32-wasmer-wasi -Zunstable-options --print target-spec-json \
#          | jq '.["target-family"]=["wasm","unix"]' > wasm32-wasmer-wasi.json
#   3. build-std with the wasix rustc + a recent nightly cargo (json target needs -Zjson-target-spec):
#        RUSTC="$SYS/bin/rustc" RUSTUP_TOOLCHAIN=nightly \
#          cargo build --release -Z build-std=std,panic_abort -Z json-target-spec \
#          --target wasm32-wasmer-wasi.json
#   VERIFIED TO HERE: std/core/alloc compile for family=unix; `cfg(unix)` activates correctly.
#
# THE LAST MILE — the ONE remaining blocker (this is the real §7 work)
#   With family=unix active, the `libc` crate now compiles its `src/unix/mod.rs`, which references the
#   POSIX type surface (`termios`, `speed_t`, `time_t`, `cc_t`, `tcflag_t`, the `termios` struct, the
#   `tc*`/`cf*` consts, …). The wasix libc fork (`wasix-org/libc`, branch wasix-0.2.169) NEVER filled
#   these for the wasi target because it was always built with family=wasm — so the module was never
#   compiled. ~400 cascading errors, rooted in a few dozen missing type/const defs. THE TASK:
#     • clone wasix-org/libc, add the wasi/wasix unix type+const surface (mirror the C wasix-libc headers
#       at /private/tmp/wasix-sysroot/.../sysroot/include: termios.h, sys/types.h, …), gated for the target
#     • redirect ALL libc in the std graph to that fork (a transitive stock `libc-0.2.174` is pulled by
#       backtrace/std_detect and ALSO tries its unix module — unify via [patch] in library/Cargo.toml)
#     • re-run build-std until green, then compile the blocked/ fixtures (next section)
#   This is iterative but LOCAL and bounded — no provisioned machine, no fly, no bootstrap.
set -euo pipefail
echo "This script documents the proven local build-std path (see header). Run the steps interactively;"
echo "the last mile is the wasix-libc unix type-surface patch. bd wb-dkwy carries the live status."

VERIFY_DIR="$(cd "$(dirname "$0")/../test/conformance/wasix/blocked" 2>/dev/null && pwd || true)"
[ -n "${VERIFY_DIR:-}" ] && echo "Pre-staged blocked crates to compile once libc is patched: $VERIFY_DIR"
