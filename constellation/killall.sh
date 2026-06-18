#!/bin/sh
# Kill the bench process tree (wrappers + binaries). NOT go.sh — go.sh is our caller; killing
# it here would be suicide and abort the relaunch before it starts.
for p in bench.sh 'llama-' fetch-model fetch-granite; do pkill -f "$p" 2>/dev/null; done
sleep 2
for p in bench.sh 'llama-'; do pkill -KILL -f "$p" 2>/dev/null; done
sleep 1
echo "remaining-procs=$(pgrep -fc 'llama-|bench.sh' 2>/dev/null)"
