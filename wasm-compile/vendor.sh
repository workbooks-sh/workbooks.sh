#!/usr/bin/env bash
# Assemble a fully SELF-CONTAINED copy of wasm-compile for publishing as its own repo.
# Copies the canonical recipes (runtime/compilers/<lang>/) + vendored source next to the
# spec/registry/licenses, then rewrites registry paths to be package-relative. Does NOT
# push anywhere — it only builds the dir; publishing is a separate, deliberate step.
#
#   usage: bash vendor.sh [OUTDIR]   (default: ./dist)
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
RT="$(cd "$SD/.." && pwd)/runtime"
OUT="${1:-$SD/dist}"

rm -rf "$OUT"; mkdir -p "$OUT/toolchains"
cp "$SD/README.md" "$SD/SPEC.md" "$SD/LICENSE-APACHE" "$SD/LICENSE-MIT" "$OUT/"
cp "$SD/toolchains/registry.json" "$OUT/toolchains/"
cp -r "$SD/examples" "$OUT/examples"

# vendor each lang's recipe dir (recipes + manifest + vendored source/stubs; NOT built artifacts)
for lang in c clang zig rust; do
  src="$RT/compilers/$lang"
  [ -d "$src" ] || continue
  dst="$OUT/toolchains/$lang"; mkdir -p "$dst"
  # copy everything except derived/built outputs (gitignored roots + tarballs)
  (cd "$src" && find . -type f \
     ! -path './clang-root/*' ! -path './zig-root/*' \
     ! -name '*.tgz' ! -name '*.tar.xz' ! -name '*.wasm' \
     -print0 | while IFS= read -r -d '' f; do
       mkdir -p "$dst/$(dirname "$f")"; cp "$f" "$dst/$f"
     done)
done

# rewrite registry recipe paths from runtime/compilers/<lang>/ -> toolchains/<lang>/
sed -i.bak 's#runtime/compilers/#toolchains/#g' "$OUT/toolchains/registry.json" && rm -f "$OUT/toolchains/registry.json.bak"

echo "vendored standalone package -> $OUT"
echo "(recipes fetch+sha-verify their pinned toolchains on first build; nothing built/committed here)"
