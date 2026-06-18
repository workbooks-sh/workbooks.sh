#!/bin/sh
LOG=${1:-/tmp/run.log}
echo "--- tail ---"; tail -4 "$LOG" 2>/dev/null
echo "P=$(pgrep -cf 'llama-' 2>/dev/null)"
echo "M=$(grep MemAvailable /proc/meminfo | tr -dc 0-9)"
echo "Z=$(wc -c < "$LOG" 2>/dev/null)"
