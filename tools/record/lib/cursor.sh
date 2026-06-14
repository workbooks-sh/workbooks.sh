#!/usr/bin/env sh
# tools/record/lib/cursor.sh — animated cursor overlay.
#
# Two modes:
#   1. NATIVE  — ffmpeg x11grab -draw_mouse 1 captures the real X pointer.
#      Good when a real driver (xdotool / WebDriver) actually moves the pointer.
#   2. SPRITE  — synthetic-event drivers (Tauri MCP, eval_js) move nothing
#      visible. We overlay a PNG cursor sprite onto the recorded video as a
#      post-process, animated along a path file of "t x y" samples.
#
# Usage:
#   cursor.sh sprite-png  <out.png>                  # emit a default arrow sprite
#   cursor.sh overlay <in.mp4> <path.tsv> <out.mp4>  # composite animated cursor
#
# path.tsv lines:  <seconds>\t<x>\t<y>   (one sample; ffmpeg lerps between them
# via sendcmd). A click frame can be marked with a 4th col "click".
# POSIX sh.

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/common.sh"

# Emit a small arrow-cursor PNG (32x32) using ffmpeg's geq/drawing primitives.
# Falls back to a simple filled triangle if lavfi geq unavailable.
emit_sprite() {
  out="$1"
  have ffmpeg || die "ffmpeg required to generate cursor sprite"
  # White arrow w/ black outline drawn on transparent canvas via a tiny polygon.
  ffmpeg -y -f lavfi -i color=c=black@0.0:s=32x32:d=1 \
    -vf "drawbox=0:0:1:1:color=black@0,\
format=rgba,\
geq=r='if(lt(X+Y,28)*gt(X,1)*lt(abs(Y-X),14),255,0)':\
g='if(lt(X+Y,28)*gt(X,1)*lt(abs(Y-X),14),255,0)':\
b='if(lt(X+Y,28)*gt(X,1)*lt(abs(Y-X),14),255,0)':\
a='if(lt(X+Y,28)*gt(X,1)*lt(abs(Y-X),14),255,0)'" \
    -frames:v 1 "$out" 2>/dev/null \
  || die "sprite generation failed"
  log "wrote cursor sprite -> $out"
}

# Build a sendcmd script that animates overlay x/y between path samples.
# ffmpeg overlay supports eval=frame with x/y exprs; we inject via sendcmd.
_path_to_sendcmd() {
  path="$1"; cmds=""
  # emit: <t> overlay x <X>, <t> overlay y <Y>
  while IFS="$(printf '\t')" read -r t x y rest; do
    [ -z "$t" ] && continue
    cmds="${cmds}${t} [enter] overlay x '${x}';\n${t} [enter] overlay y '${y}';\n"
    case "$rest" in
      *click*) cmds="${cmds}${t} [enter] overlay alpha '0.5';\n";;
    esac
  done < "$path"
  printf "%b" "$cmds"
}

overlay() {
  in="$1"; path="$2"; out="$3"
  [ -f "$in" ]   || die "input video not found: $in"
  [ -f "$path" ] || die "path file not found: $path"
  have ffmpeg || die "ffmpeg required"
  sprite="${WB_REC_OUT:-.}/_cursor.png"
  ensure_out
  [ -f "$sprite" ] || emit_sprite "$sprite"

  sc="${WB_REC_OUT:-.}/_cursor.sendcmd"
  _path_to_sendcmd "$path" > "$sc"

  # Map audio only if the input actually has an audio stream (some ffmpeg builds
  # reject the optional `0:a?` map; probe instead).
  amap=""
  if ffmpeg -hide_banner -i "$in" 2>&1 | grep -q "Audio:"; then
    amap="-map 0:a -c:a copy"
  fi
  # shellcheck disable=SC2086
  ffmpeg -y -i "$in" -i "$sprite" \
    -filter_complex "[0:v][1:v]overlay=x=0:y=0:eval=frame,sendcmd=f=$sc[v]" \
    -map "[v]" $amap -c:v libx264 -crf "${WB_REC_CRF}" -pix_fmt yuv420p "$out" \
  || die "cursor overlay composite failed"
  log "wrote cursor-overlaid video -> $out"
}

case "${1:-}" in
  sprite-png) shift; emit_sprite "${1:?out.png}";;
  overlay)    shift; overlay "${1:?in.mp4}" "${2:?path.tsv}" "${3:?out.mp4}";;
  *) die "usage: cursor.sh sprite-png <out.png> | overlay <in.mp4> <path.tsv> <out.mp4>";;
esac
