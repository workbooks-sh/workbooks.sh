#!/usr/bin/env sh
# tools/record/lib/deps.sh — dependency detection + (optional) install.
# Usage:  deps.sh check     # report only, exit 0 if all REQUIRED present
#         deps.sh install   # apt/apk install everything (needs root in container)
# POSIX sh.

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/common.sh"

# package_name|binary  per role. "binary" is what we probe on PATH.
# REQUIRED for the core x11grab→mp4 path; OPTIONAL extends features.
REQUIRED="Xvfb:xvfb ffmpeg:ffmpeg"
OPTIONAL="xdotool:xdotool wmctrl:wmctrl gifski:gifski asciinema:asciinema agg:agg xterm:xterm Xephyr:xserver-xephyr wf-recorder:wf-recorder fonts:fonts-dejavu-core"

_pkg_mgr() {
  if have apt-get; then echo apt
  elif have apk; then echo apk
  elif have dnf; then echo dnf
  else echo none; fi
}

_probe() {
  # arg: "binary:pkg" -> echoes "OK" or "MISSING"
  bin=${1%%:*}
  if have "$bin"; then echo OK; else echo MISSING; fi
}

cmd_check() {
  missing_req=0
  printf '%-16s %-8s %s\n' "BINARY" "STATE" "ROLE"
  printf '%-16s %-8s %s\n' "------" "-----" "----"
  for spec in $REQUIRED; do
    bin=${spec%%:*}; st=$(_probe "$spec")
    printf '%-16s %-8s %s\n' "$bin" "$st" "REQUIRED"
    [ "$st" = MISSING ] && missing_req=$((missing_req+1))
  done
  for spec in $OPTIONAL; do
    bin=${spec%%:*}; st=$(_probe "$spec")
    printf '%-16s %-8s %s\n' "$bin" "$st" "optional"
  done
  echo
  log "display server: $(display_server)   gif encoder: $(gif_encoder)   pkg mgr: $(_pkg_mgr)"
  if [ "$missing_req" -gt 0 ]; then
    err "$missing_req required dep(s) missing — run: tools/record/lib/deps.sh install"
    return 1
  fi
  log "all required deps present"
  return 0
}

cmd_install() {
  mgr=$(_pkg_mgr)
  [ "$mgr" = none ] && die "no supported package manager (apt/apk/dnf) found"
  SUDO=""
  [ "$(id -u)" != "0" ] && have sudo && SUDO="sudo"

  case "$mgr" in
    apt)
      pkgs="xvfb ffmpeg xdotool wmctrl xserver-xephyr fonts-dejavu-core x11-apps"
      $SUDO apt-get update
      DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends $pkgs
      # asciinema/agg/gifski are not always in apt; best-effort:
      DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends asciinema 2>/dev/null || \
        log "asciinema not in apt — install via pipx/cargo if terminal capture needed"
      ;;
    apk)
      pkgs="xvfb ffmpeg xdotool wmctrl xephyr font-dejavu xeyes asciinema"
      $SUDO apk add --no-cache $pkgs || die "apk install failed"
      ;;
    dnf)
      pkgs="xorg-x11-server-Xvfb ffmpeg xdotool wmctrl xorg-x11-server-Xephyr dejavu-sans-fonts asciinema"
      $SUDO dnf install -y $pkgs || die "dnf install failed"
      ;;
  esac

  # gifski + agg are Rust crates — install via cargo if available, else note.
  if ! have gifski && have cargo; then $SUDO cargo install gifski 2>/dev/null || cargo install gifski 2>/dev/null || true; fi
  if ! have agg    && have cargo; then cargo install --git https://github.com/asciinema/agg 2>/dev/null || true; fi
  have gifski || log "gifski missing — GIFs will fall back to ffmpeg palette (acceptable)"
  have agg    || log "agg missing — terminal-tutorial → video step needs agg (cargo install)"
  cmd_check
}

case "${1:-check}" in
  check)   cmd_check ;;
  install) cmd_install ;;
  *) die "usage: deps.sh [check|install]" ;;
esac
