#!/usr/bin/env sh
# tools/record/lib/common.sh — shared helpers for the Linux capture rig.
# POSIX sh. Sourced by `record` and the helper scripts. No bashisms.

# --- config (env-overridable) -------------------------------------------------
: "${WB_REC_DISPLAY:=:99}"          # virtual X display to create/use
: "${WB_REC_W:=1440}"               # capture width
: "${WB_REC_H:=900}"                # capture height
: "${WB_REC_DEPTH:=24}"             # X color depth
: "${WB_REC_FPS:=30}"               # capture framerate
: "${WB_REC_OUT:=./.rec}"           # output dir for artifacts
: "${WB_REC_STATE:=/tmp/wb-rec.json}" # PID/state file for start/stop
: "${WB_REC_CRF:=20}"               # x264 quality (lower=better)
: "${WB_REC_CURSOR:=1}"             # 1 = draw software cursor in capture
: "${WB_REC_DRAW_CURSOR:=1}"        # 1 = animated overlay cursor sprite

# --- logging ------------------------------------------------------------------
_ts() { date -u +%H:%M:%S; }
log()  { printf '[rec %s] %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '[rec %s] ERROR: %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- platform ------------------------------------------------------------------
is_linux() { [ "$(uname -s)" = "Linux" ]; }

# Detect the display server we should target.
# Echoes: x11 | wayland | none
display_server() {
  if [ -n "$WAYLAND_DISPLAY" ] && have wf-recorder; then
    echo wayland
  elif have Xvfb || [ -n "$DISPLAY" ]; then
    echo x11
  else
    echo none
  fi
}

# Pick a GIF encoder. Echoes: gifski | ffmpeg | none
gif_encoder() {
  if have gifski; then echo gifski
  elif have ffmpeg; then echo ffmpeg
  else echo none; fi
}

# JSON state read (no jq dependency — grep one key out of a flat object).
# state_file_get_any FILE KEY — read one key from an arbitrary flat-JSON file.
state_file_get_any() {
  [ -f "$1" ] || return 1
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -n1
}
# state_get KEY — read one key from the active capture state file ($WB_REC_STATE).
state_get() {
  state_file_get_any "$WB_REC_STATE" "$1"
}

ensure_out() { mkdir -p "$WB_REC_OUT"; }
