#!/usr/bin/env sh
# tools/record/lib/term.sh — terminal-tutorial capture.
# asciinema records a .cast; agg turns it into a GIF; ffmpeg → MP4.
#
# Usage:
#   term.sh rec <out.cast> -- <command...>   # record a command's TTY session
#   term.sh rec <out.cast>                   # record an interactive shell (exit to stop)
#   term.sh gif <in.cast> <out.gif>          # cast -> gif (agg)
#   term.sh mp4 <in.cast> <out.mp4>          # cast -> gif -> mp4
# POSIX sh.

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/common.sh"

: "${WB_TERM_COLS:=100}"
: "${WB_TERM_ROWS:=28}"
: "${WB_TERM_THEME:=monokai}"
: "${WB_TERM_FONT_SIZE:=16}"
: "${WB_TERM_SPEED:=1.0}"

rec() {
  out="$1"; shift
  have asciinema || die "asciinema not installed (deps.sh install)"
  ensure_out
  if [ "${1:-}" = "--" ]; then
    shift
    # Record a single command non-interactively.
    asciinema rec --overwrite --cols "$WB_TERM_COLS" --rows "$WB_TERM_ROWS" \
      -c "$*" "$out" || die "asciinema rec failed"
  else
    asciinema rec --overwrite --cols "$WB_TERM_COLS" --rows "$WB_TERM_ROWS" "$out" \
      || die "asciinema rec failed"
  fi
  log "wrote cast -> $out"
}

gif() {
  in="$1"; out="$2"
  [ -f "$in" ] || die "cast not found: $in"
  have agg || die "agg not installed (cargo install --git https://github.com/asciinema/agg)"
  agg --theme "$WB_TERM_THEME" --font-size "$WB_TERM_FONT_SIZE" --speed "$WB_TERM_SPEED" \
      "$in" "$out" || die "agg failed"
  log "wrote gif -> $out"
}

mp4() {
  in="$1"; out="$2"
  tmp="${WB_REC_OUT:-.}/_term.gif"; ensure_out
  gif "$in" "$tmp"
  have ffmpeg || die "ffmpeg required for mp4"
  # GIF -> H.264 MP4 (pad to even dims for yuv420p).
  ffmpeg -y -i "$tmp" -movflags +faststart \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -crf "${WB_REC_CRF}" -pix_fmt yuv420p "$out" || die "ffmpeg gif->mp4 failed"
  log "wrote mp4 -> $out"
}

case "${1:-}" in
  rec) shift; rec "${1:?out.cast}" "$@";;
  gif) shift; gif "${1:?in.cast}" "${2:?out.gif}";;
  mp4) shift; mp4 "${1:?in.cast}" "${2:?out.mp4}";;
  *) die "usage: term.sh rec <out.cast> [-- cmd...] | gif <in.cast> <out.gif> | mp4 <in.cast> <out.mp4>";;
esac
