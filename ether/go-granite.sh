#!/bin/sh
sh /tmp/killall.sh; rm -f /tmp/run.log
setsid sh -c 'CNV_FLAG=-st MODEL=/opt/llama/models/granite-4.1-3b-Q4_K_M.gguf bash /opt/llama/bench.sh 8' >/tmp/run.log 2>&1 </dev/null &
echo "launched pid=$!"
