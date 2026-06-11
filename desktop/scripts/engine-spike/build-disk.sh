#!/bin/bash
# build-disk.sh — OCI runtime image -> raw ext4 disk bootable in a
# Virtualization.framework VM (vfkit), no docker/podman/krunvm.
#
# Spike for wb-hhf.2 (bundle the engine inside the desktop .app).
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
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/latest-stable"
MKE2FS=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs

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

# ── 3. kernel + initramfs (Alpine netboot, aarch64) ──────────────────────────
# Virtualization.framework's VZLinuxBootLoader needs an UNCOMPRESSED arm64
# Image. Alpine's vmlinuz-virt is an EFI zboot wrapper ("MZ..zimg" header)
# with a gzip'd Image inside — unwrap it. The netboot initramfs lacks ext4.ko
# (it lives in the modloop), so we pull the matching linux-virt apk and append
# ext4 + deps as a second cpio.gz (concatenated initramfs).
[ -f vmlinuz-virt ]   || curl -fsSLO "$ALPINE_MIRROR/releases/aarch64/netboot/vmlinuz-virt"
[ -f initramfs-virt ] || curl -fsSLO "$ALPINE_MIRROR/releases/aarch64/netboot/initramfs-virt"

if [ ! -f kernel-image ]; then
  if [ "$(xxd -p -s 4 -l 4 vmlinuz-virt)" = "7a696d67" ]; then   # "zimg"
    OFF=$((0x$(xxd -p -s 8  -l 4 vmlinuz-virt | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')))
    LEN=$((0x$(xxd -p -s 12 -l 4 vmlinuz-virt | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')))
    dd if=vmlinuz-virt bs=1 skip="$OFF" count="$LEN" 2>/dev/null | gunzip > kernel-image
  else
    cp -f vmlinuz-virt kernel-image
  fi
fi

if [ ! -f initramfs-wb ]; then
  rm -rf initramfs-x addon
  mkdir -p initramfs-x
  (cd initramfs-x && gunzip -c ../initramfs-virt | cpio -idm --quiet)
  KVER=$(ls initramfs-x/lib/modules)            # e.g. 6.18.35-0-virt

  [ -f linux-virt.apk ] || curl -fsSL -o linux-virt.apk \
    "$ALPINE_MIRROR/main/aarch64/linux-virt-${KVER%-virt}.apk" || {
      echo "guess linux-virt-${KVER%-virt}.apk failed — check $ALPINE_MIRROR/main/aarch64/"; exit 1; }
  mkdir -p apk-x && tar -xzf linux-virt.apk -C apk-x 2>/dev/null || true

  # NB: in the alpine initramfs /lib is a symlink -> usr/lib. The kernel's
  # cpio unpacker REPLACES an existing symlink with a directory entry, which
  # would orphan /lib/ld-musl-* and break every exec ("/init error -2").
  # Stage the addon under usr/lib so the symlink survives.
  MODDIR="addon/usr/lib/modules/$KVER"
  for m in fs/ext4/ext4 fs/jbd2/jbd2 fs/mbcache lib/crc/crc16; do
    mkdir -p "$MODDIR/kernel/$(dirname "$m")"
    gunzip -c "apk-x/lib/modules/$KVER/kernel/$m.ko.gz" > "$MODDIR/kernel/$m.ko"
  done
  # The initramfs' modprobe is kmod, which only consults the modules.dep.bin
  # index — we can't regenerate that on macOS. Instead shadow /init with a
  # wrapper that insmods the ext4 chain directly (path-based, no index),
  # then hands off to the original alpine init (shipped as /init.alpine).
  cp -f initramfs-x/init addon/init.alpine
  cat > addon/init <<EOF
#!/bin/sh
# wb: load the ext4 stack (appended modules aren't in modules.dep.bin) plus
# the network stack the rootfs needs post-switch_root (af_packet for udhcpc,
# virtio_net for eth0 — alpine init only loads these on the ip=dhcp path).
BB=/usr/bin/busybox
for m in lib/crc/crc16 fs/mbcache fs/jbd2/jbd2 fs/ext4/ext4 \
         net/packet/af_packet net/core/failover drivers/net/net_failover \
         drivers/net/virtio_net fs/fuse/fuse fs/fuse/virtiofs; do
  \$BB insmod "/lib/modules/$KVER/kernel/\$m.ko"
done
exec /init.alpine "\$@"
EOF
  chmod 755 addon/init addon/init.alpine
  (cd addon && find . | cpio -o -H newc --quiet | gzip) > addon.cpio.gz
  cat initramfs-virt addon.cpio.gz > initramfs-wb
fi

# ── 4. inject init wrapper + static busybox into the rootfs ──────────────────
# The initramfs busybox is a minimal applet set (no ip/udhcpc) — use the full
# static one from the busybox-static apk.
if [ ! -f busybox.static ]; then
  BB_APK=$(curl -s "$ALPINE_MIRROR/main/aarch64/" | grep -o 'busybox-static-[0-9][^"]*\.apk' | head -1)
  curl -fsSL -o busybox-static.apk "$ALPINE_MIRROR/main/aarch64/$BB_APK"
  mkdir -p bb-x && tar -xzf busybox-static.apk -C bb-x 2>/dev/null || true
  cp -f bb-x/bin/busybox.static busybox.static
fi
cp -f busybox.static "$ROOTFS/usr/bin/busybox"
chmod 755 "$ROOTFS/usr/bin/busybox"

cat > "$ROOTFS/etc/udhcpc.script" <<'EOF'
#!/bin/sh
BB=/usr/bin/busybox
case "$1" in
  deconfig) $BB ip addr flush dev "$interface" ;;
  bound|renew)
    $BB ip addr flush dev "$interface"
    $BB ip addr add "$ip/$subnet" dev "$interface"
    [ -n "${router:-}" ] && $BB ip route add default via "${router%% *}" dev "$interface"
    [ -n "${dns:-}" ] && { for d in $dns; do echo "nameserver $d"; done > /etc/resolv.conf; }
    ;;
esac
EOF
chmod 755 "$ROOTFS/etc/udhcpc.script"

cat > "$ROOTFS/sbin/wb-init" <<'EOF'
#!/bin/bash
# PID-1 wrapper: mount API filesystems, DHCP, then exec the runtime release.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec > /dev/console 2>&1 || true
BB=/usr/bin/busybox

mount -t proc     proc /proc        2>/dev/null
mount -o remount,rw /               2>/dev/null || $BB mount -o remount,rw /
mount -t sysfs    sys  /sys         2>/dev/null
mount -t devtmpfs dev  /dev         2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp /data /disco
mount -t devpts devpts /dev/pts     2>/dev/null
mount -t tmpfs  tmpfs  /dev/shm     2>/dev/null
mount -t tmpfs  tmpfs  /run         2>/dev/null
chmod 1777 /tmp /dev/shm
# host-shared discovery dir (vfkit --device virtio-fs,...,mountTag=disco);
# harmless no-op when the tag isn't present
mount -t virtiofs disco /disco || $BB mount -t virtiofs disco /disco || echo "wb-init: virtiofs mount failed"

echo workbooks > /proc/sys/kernel/hostname
grep -q workbooks /etc/hosts 2>/dev/null || echo "127.0.0.1 localhost workbooks" > /etc/hosts

$BB ip link set lo up
$BB ip link set eth0 up
$BB udhcpc -i eth0 -s /etc/udhcpc.script -q -t 10 -T 1 -n || echo "wb-init: dhcp failed"
$BB ip addr show eth0 | grep 'inet '

export LANG=C.UTF-8 HOME=/root RELEASE_TMP=/tmp
export WB_WEB=1 PORT=4000 WB_MODELS_DIR=/opt/models
export WB_DESKTOP=1 WB_DESKTOP_DIR=/disco WB_DATA=/data WB_EMBED=local

cd /app
echo "wb-init: starting runtime ($(date))"
exec bin/workbooks start
EOF
chmod 755 "$ROOTFS/sbin/wb-init"

# ── 5. rootfs -> raw ext4 image ──────────────────────────────────────────────
rm -f disk.img
"$MKE2FS" -q -t ext4 -E root_owner=0:0 -d "$ROOTFS" -F disk.img "$DISK_SIZE"

echo "OK: $WORK/disk.img ($DISK_SIZE), kernel=kernel-image, initrd=initramfs-wb"
