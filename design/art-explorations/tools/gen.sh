#!/usr/bin/env bash
# gen.sh — generate one image via OpenRouter and save it as a PNG.
#
# usage: gen.sh <subdir> <name> "<prompt>"
#   writes design/art-explorations/<subdir>/<name>.png
#
# API key is read at runtime from ~/.config/openrouter/key (never logged).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: gen.sh <subdir> <name> \"<prompt>\"" >&2
  exit 2
fi

SUBDIR="$1"
NAME="$2"
PROMPT="$3"

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART_ROOT="$(dirname "$TOOLS_DIR")" # design/art-explorations
OUT_DIR="$ART_ROOT/$SUBDIR"
OUT_FILE="$OUT_DIR/$NAME.png"
KEY_FILE="$HOME/.config/openrouter/key"
NOTES_FILE="$TOOLS_DIR/NOTES.md"

PRIMARY_MODEL="openai/gpt-5.4-image-2"
FALLBACK_MODEL="google/gemini-3.1-flash-image-preview"
ATTEMPTS_PER_MODEL=3
ENDPOINT="https://openrouter.ai/api/v1/chat/completions"

if [[ ! -s "$KEY_FILE" ]]; then
  echo "error: API key not found at ~/.config/openrouter/key" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

# NB: BSD mktemp requires the X's to be trailing — no suffix after them.
RESP_FILE="$(mktemp /tmp/gen-or-resp.XXXXXX)"
trap 'rm -f "$RESP_FILE"' EXIT

# call_api <model> -> sets HTTP_CODE; response body in $RESP_FILE
call_api() {
  local model="$1" body
  body=$(jq -n --arg model "$model" --arg prompt "$PROMPT" '{
    model: $model,
    messages: [{role: "user", content: $prompt}],
    modalities: ["image", "text"]
  }')
  HTTP_CODE=$(curl -sS -m 300 -o "$RESP_FILE" -w '%{http_code}' "$ENDPOINT" \
    -H "Authorization: Bearer $(cat "$KEY_FILE")" \
    -H "Content-Type: application/json" \
    -d "$body" || echo "000")
}

# extract_png -> writes $OUT_FILE from first image data URL in $RESP_FILE; rc 1 if absent
extract_png() {
  local url_len
  url_len=$(jq -r '.choices[0].message.images[0].image_url.url // "" | length' "$RESP_FILE")
  [[ "$url_len" -gt 100 ]] || return 1
  mkdir -p "$OUT_DIR"
  # strip the "data:image/png;base64," prefix (mime-agnostic) and decode
  jq -r '.choices[0].message.images[0].image_url.url | sub("^data:[^,]*,"; "")' "$RESP_FILE" \
    | base64 -d > "$OUT_FILE"
}

# print API error body (response bodies never contain our key; auth header is never echoed)
print_error() {
  local model="$1"
  echo "API call failed (model=$model http=$HTTP_CODE). Response body:" >&2
  jq . "$RESP_FILE" >&2 2>/dev/null || cat "$RESP_FILE" >&2
}

try_model() {
  local model="$1" i
  for ((i = 1; i <= ATTEMPTS_PER_MODEL; i++)); do
    call_api "$model"
    if [[ "$HTTP_CODE" == "200" ]] && extract_png; then
      return 0
    fi
    echo "attempt $i/$ATTEMPTS_PER_MODEL failed for $model (http=$HTTP_CODE)" >&2
    sleep $((i * 2))
  done
  return 1
}

if try_model "$PRIMARY_MODEL"; then
  MODEL_USED="$PRIMARY_MODEL"
else
  print_error "$PRIMARY_MODEL"
  echo "primary model failed persistently; falling back to $FALLBACK_MODEL" >&2
  if try_model "$FALLBACK_MODEL"; then
    MODEL_USED="$FALLBACK_MODEL"
    printf '\n- %s: primary model %s failed persistently for %s/%s.png; used fallback %s\n' \
      "$(date +%Y-%m-%d)" "$PRIMARY_MODEL" "$SUBDIR" "$NAME" "$FALLBACK_MODEL" >> "$NOTES_FILE"
  else
    print_error "$FALLBACK_MODEL"
    echo "error: both models failed; no image written" >&2
    exit 1
  fi
fi

# sanity: PNG magic + non-trivial size
if ! head -c 8 "$OUT_FILE" | od -An -tx1 | tr -d ' \n' | grep -q '^89504e470d0a1a0a$'; then
  echo "error: output is not a valid PNG: $OUT_FILE" >&2
  exit 1
fi
SIZE=$(wc -c < "$OUT_FILE" | tr -d ' ')
echo "wrote $OUT_FILE (${SIZE} bytes, model=$MODEL_USED)"
