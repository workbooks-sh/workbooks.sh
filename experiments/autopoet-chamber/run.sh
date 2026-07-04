#!/bin/sh
set -e
cd "$(dirname "$0")"
for s in spikes/01_hebbian_graph.exs spikes/02_surprise_gate.exs spikes/03_bucket_brigade.exs; do
  echo "\n────────────────────────── $s ──────────────────────────"
  elixir "$s"
done
echo "\nspike 4 (needs nexus compiled):"
echo "  cd ../nexus && mix run --no-start ../autopoet-chamber/spikes/04_nexus_probe.exs"
