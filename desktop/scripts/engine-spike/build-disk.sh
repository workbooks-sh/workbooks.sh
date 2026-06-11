#!/bin/bash
# build-disk.sh — OCI runtime image -> raw ext4 disk bootable in a
# Virtualization.framework VM (vfkit), no docker/podman/krunvm.
#
# macOS spike entry point for wb-hhf.2. The rootfs-prep recipe itself lives in
# ../engine-disk/lib.sh — ONE source of truth shared with the Linux CI builder
# (.github/workflows/engine-disk.yml → engine-disk/build-ci.sh). Only the
# rootfs ACQUISITION differs: skopeo+umoci here (no docker on macOS),
# docker create+export on the CI runner.
#
# Produces in $WORK:
#   disk.img        raw ext4 root filesystem (runtime rootfs + init wrapper)
#   kernel-image    Alpine arm64 kernel, unwrapped to a raw uncompressed Image
#   initramfs-wb    Alpine netboot initramfs + appended ext4/jbd2/mbcache/crc16 modules
#
# Host deps (brew): skopeo umoci e2fsprogs  (HOMEBREW_NO_AUTO_UPDATE=1 brew install ...)
set -euo pipefail

WORK="${WORK:-/tmp/wb-spike}"
IMAGE="${IMAGE:-ghcr.io/workbooks-sh/runtime:latest}"
DISK_SIZE="${DISK_SIZE:-3G}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../engine-disk/lib.sh"

mkdir -p "$WORK"
cd "$WORK"

# ── 1. OCI image -> oci layout ───────────────────────────────────────────────
# brew skopeo ships a v1 registries.conf that skopeo rejects; feed it a v2 one.
if [ ! -f oci/index.json ]; then
  printf 'unqualified-search-registries = ["docker.io"]\n' > registries.conf
  skopeo --registries-conf "$WORK/registries.conf" copy \
    "docker://$IMAGE" oci:oci:latest --override-os linux --override-arch arm64
fi

# ── 2. layers -> rootfs ──────────────────────────────────────────────────────
if [ ! -d bundle/rootfs/app ]; then
  umoci unpack --rootless --image oci:latest bundle
fi
ROOTFS="$WORK/bundle/rootfs"

# ── 3-5. kernel + initramfs, boot glue, ext4 (shared with CI) ────────────────
fetch_kernel_initramfs
inject_rootfs "$ROOTFS"
make_disk "$ROOTFS" disk.img "$DISK_SIZE"

echo "OK: $WORK/disk.img ($DISK_SIZE), kernel=kernel-image, initrd=initramfs-wb"
