#!/bin/bash
# Build Alpine Linux (armhf) as an initramfs for the DSM-232 and the U-Boot files for a USB stick.
# Needs: curl sha256sum tar cpio gzip mkimage (u-boot-tools). No root needed.
# Output (copy to the root of a FAT32 USB stick, together with linux-7.2/uImage): out/uInitrd out/boot.scr
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
BRANCH=${BRANCH:-latest-stable}
mkdir -p "$OUT"
cd "$OUT"

# 1. latest armhf minirootfs, checked against the release sha256
read -r FILE SHA < <(curl -fsSL "$MIRROR/$BRANCH/releases/armhf/latest-releases.yaml" | awk '
	function emit() { if (f == "alpine-minirootfs") print file, sha }
	/^-/ { emit(); f = file = sha = "" }
	{ gsub(/"/, "") }
	$1 == "flavor:" { f = $2 } $1 == "file:" { file = $2 } $1 == "sha256:" { sha = $2 }
	END { emit() }') || true
[ -n "${FILE:-}" ] && [ -n "${SHA:-}" ] || { echo "minirootfs not found in latest-releases.yaml" >&2; exit 1; }
[ -f "$FILE" ] || curl -fL -o "$FILE" "$MIRROR/$BRANCH/releases/armhf/$FILE"
echo "$SHA  $FILE" | sha256sum -c -

# 2. rootfs + boot glue
[ -d rootfs ] && chmod -R u+w rootfs  # minirootfs has read-only dirs
rm -rf rootfs
mkdir rootfs
tar -xzpf "$FILE" -C rootfs
cat > rootfs/init <<'EOF'
#!/bin/sh
# initramfs: /dev is not auto-mounted, so do it before busybox init opens the ttys
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run
exec /bin/busybox init
EOF
chmod 755 rootfs/init
# busybox init instead of OpenRC (not in minirootfs): a login on HDMI (tty1) and UART (ttyS0)
cat > rootfs/etc/inittab <<'EOF'
::sysinit:/bin/hostname -F /etc/hostname
tty1::respawn:/sbin/getty 38400 tty1 linux
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
echo dsm232 > rootfs/etc/hostname
for f in bin/busybox sbin/getty bin/login bin/hostname etc/shadow; do
	[ -e "rootfs/$f" ] || [ -L "rootfs/$f" ] || { echo "rootfs/$f missing in $FILE" >&2; exit 1; }
done
# shortcut: root has an empty password (no network in this kernel); set one with passwd, or edit here before release
sed -i 's/^root:[^:]*:/root::/' rootfs/etc/shadow
grep -qx ttyS0 rootfs/etc/securetty 2>/dev/null || echo ttyS0 >> rootfs/etc/securetty
grep -qx tty1 rootfs/etc/securetty || echo tty1 >> rootfs/etc/securetty

(cd rootfs && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) | gzip -9 > initramfs.cpio.gz
mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n "${FILE%.tar.gz} dsm232" -d initramfs.cpio.gz uInitrd
mkimage -A arm -O linux -T script -C none -n "dsm232 usb boot" -d "$HERE/boot.cmd" boot.scr

# boot.cmd loads uInitrd at 0x5000000 and boot.scr at 0x6000000: keep the ramdisk below 16MB
size=$(stat -c %s uInitrd)
[ "$size" -lt $((0x1000000)) ] || { echo "uInitrd is $size bytes, over 16MB" >&2; exit 1; }
echo "built: $OUT/uInitrd ($size bytes) $OUT/boot.scr"
