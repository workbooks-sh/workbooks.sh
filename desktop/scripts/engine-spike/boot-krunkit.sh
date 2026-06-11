#!/bin/bash
# boot-krunkit.sh — attempt to boot the build-disk.sh disk with krunkit
# (brew install slp/krun/krunkit).
#
# FINDING (2026-06-10): krunkit 1.2.1 / libkrun-efi can ONLY boot via EFI —
# there is no --kernel/--initrd direct-kernel path. A raw ext4 filesystem
# image has no ESP/bootloader, so EDK2 has nothing to boot. krunkit would
# need a GPT disk with an ESP + arm64 bootloader baked in (podman-machine
# style), which defeats the "simple raw ext4" goal. Kept for the record.
set -euo pipefail

WORK="${WORK:-/tmp/wb-spike}"
TIMEOUT="${TIMEOUT:-60}"
KRUNKIT=$(command -v krunkit || echo /opt/homebrew/bin/krunkit)
LOG="$WORK/krunkit.log"
PIDFILE="$WORK/krunkit.pid"

cleanup() { [ -f "$PIDFILE" ] && { kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; }; }
trap cleanup EXIT

"$KRUNKIT" \
  --cpus 2 --memory 2048 \
  --bootloader "efi,variable-store=$WORK/efi-vars,create" \
  --device "virtio-blk,path=$WORK/disk.img" \
  --device "virtio-serial,logFilePath=$WORK/krunkit-console.log" \
  --restful-uri "tcp://127.0.0.1:4198" \
  --krun-log-level 3 \
  >"$LOG" 2>&1 &
echo $! > "$PIDFILE"

sleep "$TIMEOUT"
echo "--- krunkit log ---";          tail -20 "$LOG" || true
echo "--- guest console ---";        tail -20 "$WORK/krunkit-console.log" 2>/dev/null || echo "(no console output)"
