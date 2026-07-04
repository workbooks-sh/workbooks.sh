#!/usr/bin/env bash
# check-deps.sh — the monorepo DAG lock (see RESTRUCTURE.md). The anti-fusion enforcement.
#
# Product DAG — deps point DOWN only:
#     tiny-lasers  <-  {cli, nexus, compilers}  <-  {autopoet, cloud}
#   and NOTHING may depend on experiments/.
#
# A folder may reference folders BELOW it, never a sibling at its level or anything ABOVE.
# Run in CI on every PR; a violation fails the build so two surfaces can never fuse again.
set -uo pipefail
fail=0
inc=(--include="*.ex" --include="*.exs" --include="*.zig" --include="*.sh" --include="*.yml" --include="*.work" --include="*.js" --include="*.svelte")
exc=(--exclude-dir=.git --exclude-dir=_build --exclude-dir=deps --exclude-dir=node_modules --exclude-dir=build --exclude-dir=compilers-dist --exclude-dir=wasm-video --exclude-dir=vendor --exclude-dir=.zig-cache --exclude-dir=priv)

viol() { echo "❌ DAG VIOLATION — $1"; echo "$2" | sed 's/^/      /'; fail=1; }

# Rule 1: no product root may reference experiments/ (pet projects / dead code).
for root in nexus cli tiny-lasers compilers cloud autopoet; do
  [ -d "$root" ] || continue
  h=$(grep -rlE "experiments/" "$root" "${inc[@]}" "${exc[@]}" 2>/dev/null || true)
  [ -n "$h" ] && viol "$root/ references experiments/" "$h"
done

# Rule 2: a lower layer must not path-dep an upper layer.
#   nexus / cli / compilers must NOT depend on cloud/ or autopoet/.
for low in nexus cli compilers tiny-lasers; do
  [ -d "$low" ] || continue
  for up in cloud autopoet; do
    h=$(grep -rlE "path:[^,]*\b$up\b|\.\./$up/" "$low" --include="mix.exs" --include="*.zig" 2>/dev/null || true)
    [ -n "$h" ] && viol "$low/ path-deps the upper product $up/" "$h"
  done
done

# Rule 3: sibling products must not import each other (autopoet ⇎ cloud). They only share nexus.
for a in autopoet cloud; do for b in autopoet cloud; do
  [ "$a" = "$b" ] && continue; [ -d "$a" ] || continue
  h=$(grep -rlE "path:[^,]*\b$b\b" "$a" --include="mix.exs" 2>/dev/null || true)
  [ -n "$h" ] && viol "sibling products fused: $a/ deps $b/" "$h"
done; done

if [ "$fail" = 0 ]; then echo "✅ DAG OK — deps point down only, no fusion."; else
  echo ""; echo "The monorepo DAG is: tiny-lasers <- {cli,nexus,compilers} <- {autopoet,cloud}; nothing deps experiments/."; exit 1; fi
