#!/usr/bin/env bash
# Active watchdog for a detached remote bench. Polls the remote run-log + health every
# INTERVAL seconds and EXITS (which re-pings the agent) the moment it sees a terminal or
# unhealthy state: DONE / FATAL / process-gone / OOM-imminent / stalled-log.
# usage: watch.sh <fly-app> <remote-log> [interval=25] [maxiters=90]
set -uo pipefail
APP=$1; LOG=$2; INTERVAL=${3:-25}; MAXITERS=${4:-90}
prev_size=-1; stale=0

# Remote probe is a file on the machine (sh /tmp/probe.sh) so there is NO inline quoting to
# expand locally — the $(...) inside probe.sh run on the machine, not here.
for i in $(seq 1 "$MAXITERS"); do
  snap=$(fly ssh console -a "$APP" -C "sh /tmp/probe.sh $LOG" 2>/dev/null | grep -av 'Connecting')
  P=$(printf '%s\n' "$snap" | sed -n 's/^P=//p' | tr -dc 0-9); P=${P:-0}
  M=$(printf '%s\n' "$snap" | sed -n 's/^M=//p' | tr -dc 0-9); M=${M:-999999}
  Z=$(printf '%s\n' "$snap" | sed -n 's/^Z=//p' | tr -dc 0-9); Z=${Z:-0}

  if printf '%s' "$snap" | grep -q 'DONE\.'; then echo "[$APP] ✅ COMPLETE"; printf '%s\n' "$snap"; exit 0; fi
  if printf '%s' "$snap" | grep -qi 'FATAL'; then echo "[$APP] ❌ FATAL"; printf '%s\n' "$snap"; exit 1; fi
  # OOM-imminent: < 250MB available
  if [ "$M" -lt 256000 ]; then echo "[$APP] ⚠️ OOM-IMMINENT (avail ${M}kB)"; printf '%s\n' "$snap"; exit 3; fi
  # stalled log: size unchanged across polls. Only a problem if NO process is alive — a long
  # concurrency-sweep iteration is silent while N streams run, which is normal, not a stall.
  if [ "$Z" = "$prev_size" ]; then stale=$((stale+1)); else stale=0; fi
  prev_size=$Z
  if [ "$stale" -ge 8 ] && [ "$P" -eq 0 ]; then echo "[$APP] ⚠️ STALLED+IDLE (${stale} polls, 0 procs)"; printf '%s\n' "$snap"; exit 4; fi
  # process gone but not DONE -> died
  if [ "$P" -eq 0 ] && [ "$Z" -gt 0 ] && [ "$i" -gt 2 ]; then
    if ! printf '%s' "$snap" | grep -q 'sweep\|streams='; then :; fi
    echo "[$APP] ⚠️ NO llama PROC (died or between steps) — tail:"; printf '%s\n' "$snap";
    # one grace re-check next loop; if still gone, exit
    if [ "${nproc_grace:-0}" -eq 1 ]; then exit 5; fi
    nproc_grace=1
  else
    nproc_grace=0
  fi
  sleep "$INTERVAL"
done
echo "[$APP] ⏱️ watchdog max iters reached (still running)"; printf '%s\n' "$snap"; exit 0
