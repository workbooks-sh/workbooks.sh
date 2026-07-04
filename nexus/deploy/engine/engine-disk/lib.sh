# lib.sh — shared rootfs-prep for the vfkit engine disk (wb-hhf.2).
#
# Sourced by BOTH disk builders so the boot recipe has ONE home:
#   - nexus/deploy/engine/engine-spike/build-disk.sh  (macOS, skopeo+umoci rootfs)
#   - nexus/deploy/engine/engine-disk/build-ci.sh     (Linux CI, docker export rootfs)
#
# Functions operate in $PWD (the work dir) and cache downloads there, so warm
# re-runs skip the network. Alpine is PINNED — the kernel/initramfs pair moves
# deliberately on a branch bump, never because latest-stable rolled under us.

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.23}"   # linux-virt 6.18.x — the pair the spike proved
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH}"
MKE2FS="${MKE2FS:-$(command -v mke2fs || echo /opt/homebrew/opt/e2fsprogs/sbin/mke2fs)}"

# Alpine arm64 netboot kernel + initramfs → kernel-image + initramfs-wb.
# Virtualization.framework's VZLinuxBootLoader needs an UNCOMPRESSED arm64
# Image; Alpine's vmlinuz-virt is an EFI zboot wrapper ("MZ..zimg" header)
# with a gzip'd Image inside — unwrap it (payload offset/size at bytes 8/12).
# The netboot initramfs lacks ext4.ko (it lives in the modloop), so we pull
# the matching linux-virt apk and append ext4 + deps as a second cpio.gz.
fetch_kernel_initramfs() {
  # Kernel, initramfs AND modules all come from the SAME netboot release, so
  # they can never drift. (The earlier apk approach pulled the kernel from the
  # rolling main/ apk — 6.18.35 — while the base initramfs stayed at the netboot
  # version — 6.18.22 — and the mismatch left virtio unloadable: root-mount
  # failed into an emergency shell. The ext4/net/fuse modules the init wrapper
  # needs live in the modloop squashfs, version-matched to this very kernel.)
  [ -f vmlinuz-virt ]   || curl -fsSLO "$ALPINE_MIRROR/releases/aarch64/netboot/vmlinuz-virt"
  [ -f initramfs-virt ] || curl -fsSLO "$ALPINE_MIRROR/releases/aarch64/netboot/initramfs-virt"
  [ -f modloop-virt ]   || curl -fsSLO "$ALPINE_MIRROR/releases/aarch64/netboot/modloop-virt"

  if [ ! -f kernel-image ]; then
    if [ "$(xxd -p -s 4 -l 4 vmlinuz-virt)" = "7a696d67" ]; then   # "zimg"
      local OFF LEN
      OFF=$((0x$(xxd -p -s 8  -l 4 vmlinuz-virt | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')))
      LEN=$((0x$(xxd -p -s 12 -l 4 vmlinuz-virt | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')))
      dd if=vmlinuz-virt bs=1 skip="$OFF" count="$LEN" 2>/dev/null | gunzip > kernel-image
    else
      cp -f vmlinuz-virt kernel-image
    fi
  fi

  if [ ! -f initramfs-wb ]; then
    rm -rf initramfs-x addon modloop-x
    mkdir -p initramfs-x
    (cd initramfs-x && gunzip -c ../initramfs-virt | cpio -idm --quiet)
    local KVER
    KVER=$(ls initramfs-x/lib/modules)            # netboot version, e.g. 6.18.35-0-virt

    # The netboot initramfs ships only a minimal module set; ext4 + the net/fuse
    # stack the wrapper loads live in the modloop (squashfs). Unpack it and stage
    # them — version-matched to the netboot kernel, so insmod always succeeds.
    unsquashfs -q -f -d modloop-x modloop-virt >/dev/null 2>&1 \
      || { echo "unsquashfs modloop-virt failed — need squashfs-tools"; return 1; }
    local MODBASE
    MODBASE=$(dirname "$(find modloop-x -type d -name "$KVER" -path '*modules*' | head -1)")
    [ -n "$MODBASE" ] && [ -d "$MODBASE/$KVER" ] || { echo "modloop has no modules/$KVER"; return 1; }

    # NB: in the alpine initramfs /lib is a symlink -> usr/lib. The kernel's
    # cpio unpacker REPLACES an existing symlink with a directory entry, which
    # would orphan /lib/ld-musl-* and break every exec ("/init error -2").
    # Stage the addon under usr/lib so the symlink survives.
    local MODDIR="addon/usr/lib/modules/$KVER"
    local m src
    for m in fs/ext4/ext4 fs/jbd2/jbd2 fs/mbcache lib/crc/crc16 \
             net/packet/af_packet net/core/failover drivers/net/net_failover \
             drivers/net/virtio_net fs/fuse/fuse fs/fuse/virtiofs; do
      src="$MODBASE/$KVER/kernel/$m"
      mkdir -p "$MODDIR/kernel/$(dirname "$m")"
      if   [ -f "$src.ko.gz" ]; then gunzip -c "$src.ko.gz" > "$MODDIR/kernel/$m.ko"
      elif [ -f "$src.ko" ];    then cp -f    "$src.ko"      "$MODDIR/kernel/$m.ko"
      # ext4 chain is mandatory (the rootfs is ext4); net/fuse are best-effort.
      elif printf '%s' "$m" | grep -q '^fs/ext4\|^fs/jbd2\|^fs/mbcache\|^lib/crc'; then
        echo "required module missing in modloop: $m"; return 1
      fi
    done
    # The initramfs' modprobe is kmod, which only consults the modules.dep.bin
    # index — we can't regenerate that off-target. Instead shadow /init with a
    # wrapper that insmods the ext4 chain directly (path-based, no index),
    # then hands off to the original alpine init (shipped as /init.alpine).
    cp -f initramfs-x/init addon/init.alpine
    cat > addon/init <<EOF
#!/bin/sh
# wb: load the ext4 stack (appended modules aren't in modules.dep.bin) plus
# the network stack the rootfs needs post-switch_root (af_packet for udhcpc,
# virtio_net for eth0 — alpine init only loads these on the ip=dhcp path).
BB=/usr/bin/busybox
for m in lib/crc/crc16 fs/mbcache fs/jbd2/jbd2 fs/ext4/ext4 \\
         net/packet/af_packet net/core/failover drivers/net/net_failover \\
         drivers/net/virtio_net fs/fuse/fuse fs/fuse/virtiofs; do
  \$BB insmod "/lib/modules/$KVER/kernel/\$m.ko"
done
exec /init.alpine "\$@"
EOF
    chmod 755 addon/init addon/init.alpine
    (cd addon && find . | cpio -o -H newc --quiet | gzip) > addon.cpio.gz
    cat initramfs-virt addon.cpio.gz > initramfs-wb
  fi
}

# Inject the boot glue into an unpacked runtime rootfs: a full static busybox
# (the initramfs one is a minimal applet set — no ip/udhcpc), the udhcpc
# config script, and /sbin/wb-init (PID 1: API mounts, DHCP, exec the release).
inject_rootfs() {
  local ROOTFS="$1"

  if [ ! -f busybox.static ]; then
    local BB_APK
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
# WB_DATA on the PERSISTED host share (/disco is a virtio-fs mount of the host dir) so the tenant
# SQLite, pushed-workbook git repos + checkouts survive `down`/reboot — local↔cloud data parity. The
# in-disk /data is the per-boot clone (ephemeral); /disco/data persists on the host. mkdir is safe.
$BB mkdir -p /disco/data 2>/dev/null || mkdir -p /disco/data 2>/dev/null
export WB_DESKTOP=1 WB_DESKTOP_DIR=/disco WB_DATA=/disco/data WB_EMBED=local

# Deploy SECRETS — Nexus.Deploy.Machine writes /disco/secrets.env (the genuine deploy-injection seam,
# mirroring the cloud machine env), so a secret-gated workbook (LLM/API key) runs the same locally as
# in cloud. Source it into the release env (the values reach Nexus.Secrets via the process env).
if [ -f /disco/secrets.env ]; then set -a; . /disco/secrets.env 2>/dev/null; set +a; fi

cd /app
echo "wb-init: starting runtime ($(date))"
# The mix release is `nexus` (mix.exs app: :nexus) → /app/bin/nexus. (`bin/workbooks` does NOT exist;
# exec'ing it killed PID 1 → kernel panic. The old published disk used bin/nexus and booted fine.)
exec bin/nexus start
EOF
  chmod 755 "$ROOTFS/sbin/wb-init"
}

# rootfs → raw ext4 image. mke2fs -d needs no loop mounts and runs fully
# unprivileged on both macOS and a CI runner.
make_disk() {
  local ROOTFS="$1" OUT="$2" SIZE="$3"
  rm -f "$OUT"
  "$MKE2FS" -q -t ext4 -E root_owner=0:0 -d "$ROOTFS" -F "$OUT" "$SIZE"
}
