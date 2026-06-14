#!/usr/bin/env sh
# tools/record/trigger-from-mac.sh — Mac host trigger.
#
# The Mac host does NOT capture. Capture is Linux (canon: the app + runtime run
# in the Linux kernel — krunvm locally, cloud Linux). This script is the thin
# trigger: it shells into the Linux substrate and runs `tools/record/record`
# there, then copies artifacts back to the host.
#
# Usage:
#   trigger-from-mac.sh <record-args...>
#   trigger-from-mac.sh pipeline recipes/app-demo.example.json   # THE full loop
#   trigger-from-mac.sh selftest
#   trigger-from-mac.sh record-flow tools/record/flows/example-app.flow
#
# `pipeline` is the single proof-looped recording entrypoint (seed->capture->
# drive->verify->retry). This script execs it inside the Linux substrate (the
# only place capture is legal, per canon) and copies artifacts back.
#
# Backend seam (matches deploy-kit krunvm|podman|docker, memory deploy-kit-container-model):
#   WB_REC_BACKEND=krunvm|podman|docker|ssh   (default: auto-detect)
#   WB_REC_CONTAINER=<name/id>                (container/VM to exec into)
#   WB_REC_SSH=<user@host>                    (for cloud Linux over ssh)
#   WB_REC_REPO=/workspace/workbooks          (repo path inside the guest)
# POSIX sh.

set -eu
: "${WB_REC_REPO:=/workspace/workbooks}"
: "${WB_REC_CONTAINER:=workbooks}"

backend="${WB_REC_BACKEND:-}"
if [ -z "$backend" ]; then
  if [ -n "${WB_REC_SSH:-}" ]; then backend=ssh
  elif command -v krunvm >/dev/null 2>&1; then backend=krunvm
  elif command -v podman  >/dev/null 2>&1; then backend=podman
  elif command -v docker  >/dev/null 2>&1; then backend=docker
  else
    echo "ERROR: no Linux backend (krunvm/podman/docker/ssh). Set WB_REC_BACKEND." >&2
    exit 1
  fi
fi

REC="$WB_REC_REPO/tools/record/record"
echo "[trigger] backend=$backend container=${WB_REC_CONTAINER} -> $REC $*" >&2

case "$backend" in
  ssh)    ssh -o BatchMode=yes "${WB_REC_SSH:?WB_REC_SSH=user@host}" "sh $REC $*" ;;
  krunvm) krunvm start "$WB_REC_CONTAINER" -- sh "$REC" "$@" ;;
  podman) podman exec -i "$WB_REC_CONTAINER" sh "$REC" "$@" ;;
  docker) docker exec -i "$WB_REC_CONTAINER" sh "$REC" "$@" ;;
  *) echo "ERROR: unknown backend $backend" >&2; exit 1 ;;
esac
