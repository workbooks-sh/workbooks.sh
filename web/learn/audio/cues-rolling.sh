#!/bin/bash
# Rolling cue generation: as TTS finishes a slug's intro narration, render its
# music cues. Shard by index: cues-rolling.sh <shard> <of>. Exits when every
# verdict slug has all five cues.
set -u
SHARD=${1:-0}; OF=${2:-1}
cd "$(dirname "$0")"
SLUGS=$(python3 -c "
import json
arr=[r['slug'] for r in json.load(open('../../../docs/library-run-verdicts.json'))]
print(' '.join(arr[$SHARD::$OF]))")
while :; do
  pending=0
  for s in $SLUGS; do
    if [ -f "cues/$s-intro.mp3" ] && [ -f "cues/$s-outro.mp3" ] && [ -f "cues/$s-turn3.mp3" ]; then continue; fi
    if [ -f "align/$s--intro.json" ]; then
      node cues.mjs "$s" || echo "cues $s failed (will retry)"
    fi
    pending=1
  done
  [ "$pending" = 0 ] && break
  sleep 90
done
echo "cue shard $SHARD/$OF done"
