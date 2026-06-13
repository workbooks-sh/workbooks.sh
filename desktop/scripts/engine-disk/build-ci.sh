#!/bin/bash
# build-ci.sh — Linux CI entry point: runtime OCI image -> vfkit boot artifacts.
#
# Runs on an arm64 GitHub runner (.github/workflows/engine-disk.yml) after the
# runtime image publishes. Rootfs comes from docker create+export (the runner
# has docker; no skopeo/umoci needed); the boot recipe itself is the shared
# lib.sh — the SAME functions the macOS spike runs.
#
# Produces in $WORK:
#   disk.img.zst    raw ext4 root filesystem, zstd-compressed for distribution
#   kernel-image    Alpine arm64 kernel, unwrapped to a raw uncompressed Image
#   initramfs-wb    Alpine netboot initramfs + appended ext4/virtio modules
set -euo pipefail

WORK="${WORK:-/tmp/wb-engine-disk}"
IMAGE="${IMAGE:-ghcr.io/workbooks-sh/runtime:latest}"
DISK_SIZE="${DISK_SIZE:-3G}"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

# fetch_kernel_initramfs unpacks the Alpine modloop (squashfs) for the
# version-matched ext4/virtio modules — ensure unsquashfs is present.
command -v unsquashfs >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y squashfs-tools; }

mkdir -p "$WORK"
cd "$WORK"

# ── 1-2. OCI image -> rootfs (docker create+export — never runs the image) ───
docker pull --platform linux/arm64 "$IMAGE"
cid=$(docker create --platform linux/arm64 "$IMAGE")
rm -rf rootfs && mkdir -p rootfs
# Non-root extract: ownership becomes the runner user (mke2fs -d carries it
# as-is; the guest runs as root and reads regardless — same as the spike's
# rootless umoci). -p keeps exact modes; dev/* needs mknod, guest mounts
# devtmpfs anyway.
docker export "$cid" | tar -xpf - -C rootfs --exclude='dev/*'
docker rm -f "$cid" >/dev/null

# ── 3-5. kernel + initramfs, boot glue, ext4 (shared with the macOS spike) ───
fetch_kernel_initramfs
inject_rootfs "$WORK/rootfs"
make_disk "$WORK/rootfs" disk.img "$DISK_SIZE"

# ── 6. compress for distribution (the 3G image is mostly zeros) ──────────────
zstd -T0 -15 -f disk.img -o disk.img.zst

ls -lh disk.img.zst kernel-image initramfs-wb
echo "OK: $WORK/{disk.img.zst,kernel-image,initramfs-wb}"
