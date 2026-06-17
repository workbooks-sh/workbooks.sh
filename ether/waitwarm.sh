#!/usr/bin/env bash
# Poll bitnet warm.log + granite run.log; exit (re-ping agent) when bitnet warm result lands
# or granite hits DONE. Bounded.
for i in $(seq 1 40); do
  w=$(fly ssh console -a wb-bitnet-bench -C "sh -c 'grep -iE \"tokens per second|done 1|done 2|done 0\" /tmp/warm.log 2>/dev/null | tail -4'" 2>/dev/null | grep -avE 'Connecting')
  g=$(fly ssh console -a ether-granite-bench -C "sh -c 'grep -c DONE /tmp/run.log 2>/dev/null'" 2>/dev/null | grep -avE 'Connecting' | tr -dc 0-9)
  if printf '%s' "$w" | grep -qi 'tokens per second'; then echo "BITNET-WARM-DONE"; printf '%s\n' "$w"; echo "granite-DONE=$g"; exit 0; fi
  if [ "${g:-0}" -ge 1 ]; then echo "GRANITE-DONE"; echo "warm-so-far:"; printf '%s\n' "$w"; exit 0; fi
  sleep 20
done
echo "waiter max iters"; printf '%s\n' "$w"
