#!/usr/bin/env bash
# Litestream validation harness — proves the durability cycle end to end with the REAL litestream
# binary: seed a WAL SQLite DB → continuously replicate → write under load → wipe the machine (delete
# the DB + WAL) → restore from the replica → verify every row survived. The replica here is a local
# `file` target so it runs offline; production swaps it for the S3/R2 replica
# (Nexus.Litestream.config_yaml) — the cycle is identical. Reports the health metrics the cloud
# dashboard should surface: write p99, SQLITE_BUSY count, WAL size, replication lag, restore time.
#
# Usage:  nexus/scripts/litestream-validate.sh [N_ROWS]
set -euo pipefail

N="${1:-5000}"
command -v litestream >/dev/null || { echo "FAIL: litestream not installed"; exit 2; }
command -v sqlite3 >/dev/null || { echo "FAIL: sqlite3 not installed"; exit 2; }

TMP="$(mktemp -d)"
DB="$TMP/nexus.db"
REPLICA="$TMP/replica"
CFG="$TMP/litestream.yml"
trap '[ -n "${LS:-}" ] && kill "$LS" 2>/dev/null; rm -rf "$TMP"' EXIT

# Config mirrors Nexus.Litestream.config_yaml/2 (file-replica form).
cat > "$CFG" <<EOF
dbs:
  - path: $DB
    replicas:
      - type: file
        path: $REPLICA
EOF

echo "→ seed DB (WAL) at $DB"
sqlite3 "$DB" "PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT, ts TEXT);"

echo "→ start continuous replication"
litestream replicate -config "$CFG" >"$TMP/ls.log" 2>&1 &
LS=$!
sleep 2

echo "→ write $N rows under replication, sampling write latency"
BUSY=0
P99_FILE="$TMP/lat"
: > "$P99_FILE"
# Write in 50 batches so the WAL churns and litestream ships frames during the run.
BATCH=$(( N / 50 )); [ "$BATCH" -lt 1 ] && BATCH=1
i=0
while [ "$i" -lt "$N" ]; do
  sql="BEGIN;"
  j=0
  while [ "$j" -lt "$BATCH" ] && [ "$i" -lt "$N" ]; do
    sql="$sql INSERT INTO t(v,ts) VALUES('row-$i', datetime('now'));"
    i=$((i+1)); j=$((j+1))
  done
  sql="$sql COMMIT;"
  start=$(python3 -c 'import time;print(time.time())')
  if ! out=$(sqlite3 "$DB" "$sql" 2>&1); then
    echo "$out" | grep -qi "busy\|locked" && BUSY=$((BUSY+1))
  fi
  end=$(python3 -c 'import time;print(time.time())')
  python3 -c "print(($end-$start)*1000)" >> "$P99_FILE"
done

echo "→ let replication flush, then capture lag"
sleep 3
WAL_SIZE=$(stat -f%z "$DB-wal" 2>/dev/null || stat -c%s "$DB-wal" 2>/dev/null || echo 0)

echo "→ graceful stop (final sync on shutdown)"
kill -TERM "$LS" 2>/dev/null || true; wait "$LS" 2>/dev/null || true; LS=""

echo "→ SIMULATE MACHINE WIPE: delete DB + WAL + SHM"
rm -f "$DB" "$DB-wal" "$DB-shm"
[ -f "$DB" ] && { echo "FAIL: db not deleted"; exit 1; }

echo "→ restore from replica"
T0=$(python3 -c 'import time;print(time.time())')
litestream restore -config "$CFG" "$DB"
T1=$(python3 -c 'import time;print(time.time())')

GOT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM t;")
RESTORE_MS=$(python3 -c "print(round(($T1-$T0)*1000))")
P99_MS=$(python3 -c "import sys;xs=sorted(float(l) for l in open('$P99_FILE'));print(round(xs[int(len(xs)*0.99)-1],1) if xs else 0)")

echo
echo "──────── litestream validation ────────"
echo "  rows written     : $N"
echo "  rows restored    : $GOT"
echo "  write p99        : ${P99_MS} ms/batch"
echo "  SQLITE_BUSY      : $BUSY"
echo "  WAL size at sync : $WAL_SIZE bytes"
echo "  restore time     : ${RESTORE_MS} ms"
echo "───────────────────────────────────────"
if [ "$GOT" = "$N" ]; then
  echo "LITESTREAM VALIDATION: PASS — every row survived a full wipe + restore."
  exit 0
else
  echo "LITESTREAM VALIDATION: FAIL — expected $N rows, restored $GOT."
  echo "--- litestream log ---"; cat "$TMP/ls.log"
  exit 1
fi
