#!/usr/bin/env bash
# provision-all.sh — idempotently provision every from-source Forge lane.
#
# Each compilers/<name>/build.sh fetches+stages (or natively cross-compiles, for Go lanes) that lane's
# source/artifact and is itself idempotent (skips when already provisioned, emits the artifact/src path on
# stdout). This driver just loops them, in a safe order, with a HEAVY-lane guard so a normal run stays
# light + crash-safe on this box (see .campaign/CRASH-PROTOCOL.md).
#
# HEAVY lanes (downstream build_c_dir compile is machine-threatening — big amalgams that can OOM clang.wasm)
# are SKIPPED BY DEFAULT. Run them deliberately, one at a time, when you mean to:
#   SKIP_HEAVY=1 ./provision-all.sh     # default — FAST lanes only (Go + single-file C)
#   SKIP_HEAVY=0 ./provision-all.sh     # everything, including the heavy source stages
#   ONLY=lua,yq    ./provision-all.sh   # provision just these lanes
#
# Note: build.sh only FETCHES/STAGES source (cheap, even for "heavy" lanes — the cost is the later clang
# compile inside the test). The HEAVY flag is conservative: it keeps a default run to the lanes the rest of
# the campaign treats as cheap end-to-end. Last lines = a summary of which lanes provisioned / skipped /
# failed.
set -uo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
SKIP_HEAVY="${SKIP_HEAVY:-1}"
ONLY="${ONLY:-}"

# Lanes whose end-to-end provision→test path is heavy on this box. duckdb has no build.sh (prebuilt
# duckdb.wasm + ddb-link.sh staging) so it's never looped here regardless.
HEAVY=" treesitter pcre2 "

# Infra toolchain dirs — these are the compiler lanes themselves (clang/zig/go/rust/wasm-tools/...) and/or
# wrappers that downstream lanes depend on. They are provisioned by their own flows, not by this capability
# driver; looping them here would trigger long toolchain builds. Excluded from the capability sweep.
INFRA=" c clang go rust zig wasm-tools js svelte "

want() { case " $ONLY " in *" $1 "*) return 0;; esac; [ -z "$ONLY" ]; }
is_heavy() { case "$HEAVY" in *" $1 "*) return 0;; esac; return 1; }
is_infra() { case "$INFRA" in *" $1 "*) return 0;; esac; return 1; }

PROVISIONED=(); SKIPPED=(); FAILED=()

for bs in "$SD"/*/build.sh; do
  name="$(basename "$(dirname "$bs")")"
  is_infra "$name" && continue
  if [ -n "$ONLY" ]; then
    want "$name" || continue
  elif is_heavy "$name" && [ "$SKIP_HEAVY" = "1" ]; then
    echo "[skip-heavy] $name (set SKIP_HEAVY=0 or ONLY=$name to provision)"
    SKIPPED+=("$name"); continue
  fi
  echo "==> provisioning $name"
  if bash "$bs" >/dev/null; then
    PROVISIONED+=("$name")
  else
    echo "[FAIL] $name (exit $?)" >&2
    FAILED+=("$name")
  fi
done

echo
echo "================ provision-all summary ================"
echo "provisioned (${#PROVISIONED[@]}): ${PROVISIONED[*]:-none}"
echo "skipped-heavy (${#SKIPPED[@]}): ${SKIPPED[*]:-none}"
echo "failed (${#FAILED[@]}): ${FAILED[*]:-none}"
echo "======================================================="
[ "${#FAILED[@]}" -eq 0 ]
