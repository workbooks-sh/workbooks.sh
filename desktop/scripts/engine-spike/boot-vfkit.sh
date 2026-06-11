#!/bin/bash
# boot-vfkit.sh — boot the disk built by build-disk.sh in a
# Virtualization.framework VM via vfkit (brew install vfkit), prove the
# runtime answers HTTP across the VM boundary, report cold-boot wall time.
#
# Usage: boot-vfkit.sh [--keep]   (--keep leaves the VM running)
set -euo pipefail

WORK="${WORK:-/tmp/wb-spike}"
MAC="${MAC:-5a:94:ef:e4:1c:ee}"           # avoid leading-zero octets: dhcpd_leases strips them
TIMEOUT="${TIMEOUT:-120}"
REST_PORT="${REST_PORT:-4199}"            # NEVER 4000 — prod runtime container lives there
KEEP="${1:-}"

VFKIT=$(command -v vfkit || echo /opt/homebrew/bin/vfkit)
LOG="$WORK/vfkit.log"
PIDFILE="$WORK/vfkit.pid"

cleanup() {
  if [ "$KEEP" != "--keep" ] && [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "VM stopped."
  fi
}
trap cleanup EXIT

mkdir -p "$WORK/disco"
rm -f "$WORK/disco/runtime.json"

T0=$(date +%s)
"$VFKIT" \
  --cpus 2 --memory 2048 \
  --kernel "$WORK/kernel-image" \
  --initrd "$WORK/initramfs-wb" \
  --kernel-cmdline "console=hvc0 root=/dev/vda rw rootfstype=ext4 modules=ext4 init=/sbin/wb-init" \
  --device "virtio-blk,path=$WORK/disk.img" \
  --device "virtio-net,nat,mac=$MAC" \
  --device virtio-rng \
  --device "virtio-fs,sharedDir=$WORK/disco,mountTag=disco" \
  --device "virtio-serial,logFilePath=$WORK/console.log" \
  --restful-uri "tcp://127.0.0.1:$REST_PORT" \
  >"$LOG" 2>&1 &
echo $! > "$PIDFILE"
echo "vfkit pid $(cat "$PIDFILE"), console -> $WORK/console.log"

# ── find guest IP from the macOS Internet-Sharing DHCP lease db ──────────────
IP=""
for _ in $(seq 1 "$TIMEOUT"); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { echo "vfkit exited:"; tail -20 "$LOG"; exit 1; }
  IP=$(awk -v mac="$MAC" '
    /^\{/    {ip=""}
    /ip_address=/   {split($0,a,"="); ip=a[2]}
    /hw_address=/   {if (index($0, mac)) print ip}
  ' /var/db/dhcpd_leases 2>/dev/null | head -1)
  [ -n "$IP" ] && break
  sleep 1
done
[ -n "$IP" ] || { echo "no DHCP lease after ${TIMEOUT}s"; tail -20 "$WORK/console.log"; exit 1; }
echo "guest IP: $IP ($(($(date +%s) - T0))s)"

# ── poll the runtime's public discovery endpoint ─────────────────────────────
for _ in $(seq 1 "$TIMEOUT"); do
  CODE=$(curl -s -o "$WORK/wellknown.json" -w '%{http_code}' --max-time 2 \
    "http://$IP:4000/.well-known/workbooks-runtime" || true)
  if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
    T1=$(date +%s)
    echo "SUCCESS: HTTP $CODE from http://$IP:4000/.well-known/workbooks-runtime in $((T1 - T0))s"
    cat "$WORK/wellknown.json"; echo
    if [ -f "$WORK/disco/runtime.json" ]; then
      echo "virtio-fs discovery OK: $WORK/disco/runtime.json"
      head -c 200 "$WORK/disco/runtime.json"; echo
    else
      echo "virtio-fs discovery MISSING (guest wrote to local /disco instead)"
    fi
    [ "$KEEP" = "--keep" ] && echo "VM left running (pid $(cat "$PIDFILE"))"
    exit 0
  fi
  sleep 1
done
echo "FAIL: no HTTP response after ${TIMEOUT}s"; tail -30 "$WORK/console.log"; exit 1
