#!/bin/bash
M=/models/granite-3b.gguf; D=/models/granite-1b-draft.gguf; B=/opt/llama/build/bin/llama-cli
pkill -f llama-server 2>/dev/null; sleep 1
P="Write a complete Lit web component named wb-todo-list with methods to add, remove, and toggle items complete. Include imports, the class, the render method, and CSS styles. Return only JavaScript."
echo "=== BASELINE (no drafter) ==="
$B -m $M -p "$P" -n 256 -t 4 -c 4096 -st --no-warmup --no-display-prompt </dev/null 2>/tmp/base.err >/dev/null
grep -iE 'eval time' /tmp/base.err
echo
echo "=== SPECULATIVE (1B drafter, n-max 16) ==="
$B -m $M -md $D -p "$P" -n 256 -t 4 -c 4096 --spec-draft-n-max 16 -st --no-warmup --no-display-prompt </dev/null 2>/tmp/spec.err >/dev/null
grep -iE 'eval time' /tmp/spec.err
echo "--- draft acceptance ---"; grep -iE 'draft|accept|n_drafted|target' /tmp/spec.err | head
echo "--- any vocab/compat error? ---"; grep -iE 'error|mismatch|incompatible|vocab|abort' /tmp/spec.err | head -3
