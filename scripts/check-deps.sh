#!/usr/bin/env bash
# check-deps.sh — the monorepo DAG lock (see RESTRUCTURE.md). The anti-fusion enforcement.
# Deps point DOWN only: tiny-lasers <- {cli,nexus,compilers} <- {autopoet,cloud}. Nothing deps experiments/.
set -uo pipefail
fail=0
inc=(--include="*.ex" --include="*.exs" --include="*.zig" --include="*.sh" --include="*.yml" --include="*.work" --include="*.js" --include="*.svelte" --include="mix.exs")
exc=(--exclude-dir=.git --exclude-dir=_build --exclude-dir=deps --exclude-dir=node_modules --exclude-dir=build --exclude-dir=compilers-dist --exclude-dir=wasm-video --exclude-dir=vendor --exclude-dir=.zig-cache)

# Rule 1 (LIVE): no product root may reference experiments/.
for root in nexus cli tiny-lasers compilers cloud autopoet; do
  [ -d "$root" ] || continue
  hits=$(grep -rlE "experiments/" "$root" "${inc[@]}" "${exc[@]}" 2>/dev/null || true)
  [ -n "$hits" ] && { echo "DAG VIOLATION — $root/ references experiments/:"; echo "$hits"; fail=1; }
done

# Rule 2 (enable once cloud/ + autopoet/ extract): nexus/cli/compilers must not depend UP on cloud/autopoet.
# for up in cloud autopoet; do
#   hits=$(grep -rlE "path:.*\b$up\b" nexus/mix.exs cli 2>/dev/null || true)
#   [ -n "$hits" ] && { echo "DAG VIOLATION — a lower root depends on $up/"; echo "$hits"; fail=1; }
# done

[ "$fail" = 0 ] && echo "DAG OK — no upward deps." || exit 1
