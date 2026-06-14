#!/usr/bin/env bash
# Bundle @work.books/wavelet-runtime (the gm-* web-component player at
# runtime/wavelet/runtime) into a single self-contained ESM file that the
# desktop WaveletPlayer injects into a composition iframe when the
# composition uses the gm-* element family. Plain HTML+CSS compositions
# (the render-core vocabulary) don't need this — they animate natively and
# are driven deterministically via the Web Animations API.
#
# Reproducible: re-run after editing the wavelet runtime submodule.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
desktop="$(dirname "$here")"
runtime_src="$desktop/../runtime/wavelet/runtime/src/runtime.ts"
out="$desktop/static/wavelet/wavelet-runtime.js"

if [[ ! -f "$runtime_src" ]]; then
  echo "wavelet runtime source not found: $runtime_src" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
bun build "$runtime_src" --outfile "$out" --format esm --target browser
echo "wrote $out"
