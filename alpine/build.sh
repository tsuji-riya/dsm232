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

# 2a. Wi-Fi userland and AR6003 firmware from the armhf repositories of the minirootfs, installed by
# the static apk of the build machine (signatures checked with the minirootfs keys; no armhf scripts run)
HOSTARCH=$(uname -m)
APKV=$(curl -fsSL "$MIRROR/$BRANCH/main/$HOSTARCH/APKINDEX.tar.gz" | tar -xzO APKINDEX |
	awk -F: '$1 == "P" { p = $2 } $1 == "V" && p == "apk-tools-static" { v = $2 } END { print v }')
[ -n "$APKV" ] || { echo "apk-tools-static not found for $HOSTARCH" >&2; exit 1; }
[ -f "apk-tools-static-$APKV-$HOSTARCH.apk" ] ||
	curl -fL -o "apk-tools-static-$APKV-$HOSTARCH.apk" "$MIRROR/$BRANCH/main/$HOSTARCH/apk-tools-static-$APKV.apk"
mkdir -p apk && tar -xzif "apk-tools-static-$APKV-$HOSTARCH.apk" -C apk sbin/apk.static
# keys and repositories: those under --root
apk/sbin/apk.static --root rootfs --arch armhf --no-scripts --no-cache --usermode \
	add wpa_supplicant iw wireless-regdb linux-firmware-ath6k
# keep the firmware of the DSM-232 chip only (AR6003 hw2.1.1; zstd files, symlinks resolved)
fw=rootfs/lib/firmware/ath6k
cp -rL "$fw/AR6003/hw2.1.1" hw2.1.1 && rm -rf "$fw" && mkdir -p "$fw/AR6003" && mv hw2.1.1 "$fw/AR6003/"
# optional board data of the vendor (bdata_jp/us/gb.bin of the GPL package; not redistributable here).
# Without it ath6kl falls back to the generic bdata.SD31.bin of linux-firmware.
[ ! -f "$HERE/bdata.bin" ] || install -m 644 "$HERE/bdata.bin" rootfs/lib/firmware/ath6k/AR6003/hw2.1.1/bdata.bin

cat > rootfs/init <<'EOF'
#!/bin/sh
# initramfs: /dev is not auto-mounted, so do it before busybox init opens the ttys
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run
# root=/dev/sdXN on the kernel command line: switch to that file system (ext4 on the USB stick,
# partition 2 of out/dsm232-usb.img); anything else (root=ram) stays in the initramfs
for a in $(cat /proc/cmdline); do case $a in root=*) root=${a#root=} ;; esac; done
if [ "${root#/dev/}" != "${root:-}" ]; then
	for i in $(seq 20); do [ -b "$root" ] && break; echo "waiting for $root"; sleep 1; done
	mkdir -p /newroot
	if mount "$root" /newroot && [ -x /newroot/sbin/init ]; then
		for m in dev proc sys run; do mount --move /$m /newroot/$m; done
		exec switch_root /newroot /sbin/init
	fi
	echo "cannot use $root as root file system, staying in the initramfs"
	umount /newroot 2>/dev/null
fi
exec /bin/busybox init
EOF
chmod 755 rootfs/init
# busybox init instead of OpenRC (not in minirootfs): a login on HDMI (tty1) and UART (ttyS0)
cat > rootfs/etc/inittab <<'EOF'
::sysinit:/bin/hostname -F /etc/hostname
::once:/usr/local/sbin/dsm232-net
tty1::respawn:/sbin/getty 38400 tty1 linux
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
echo dsm232 > rootfs/etc/hostname
# Wi-Fi at boot once /etc/wpa_supplicant.conf exists (made with wpa_passphrase); then NTP, since
# there is no RTC and TLS (apk) fails with the clock at 1970
mkdir -p rootfs/usr/local/sbin
cat > rootfs/usr/local/sbin/dsm232-net <<'EOF'
#!/bin/sh
conf=/etc/wpa_supplicant.conf
[ -f "$conf" ] || exit 0
for i in $(seq 30); do [ -e /sys/class/net/wlan0 ] && break; sleep 1; done
wpa_supplicant -B -i wlan0 -c "$conf" || exit 1
udhcpc -i wlan0 -b
ntpd -p pool.ntp.org
EOF
chmod 755 rootfs/usr/local/sbin/dsm232-net
for f in bin/busybox sbin/getty bin/login bin/hostname etc/shadow; do
	[ -e "rootfs/$f" ] || [ -L "rootfs/$f" ] || { echo "rootfs/$f missing in $FILE" >&2; exit 1; }
done
# shortcut: root has an empty password (no network login service is installed); set one with passwd, or edit here before release
sed -i 's/^root:[^:]*:/root::/' rootfs/etc/shadow
grep -qx ttyS0 rootfs/etc/securetty 2>/dev/null || echo ttyS0 >> rootfs/etc/securetty
grep -qx tty1 rootfs/etc/securetty || echo tty1 >> rootfs/etc/securetty

(cd rootfs && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) | gzip -9 > initramfs.cpio.gz
# the same tree as a tarball, e.g. for a larger ext4 root (extract as root, see docs/LINUX_PERIPHERALS.md)
tar -czf rootfs.tar.gz --numeric-owner --owner=0 --group=0 -C rootfs .
mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n "${FILE%.tar.gz} dsm232" -d initramfs.cpio.gz uInitrd
python3 -I "$HERE/../tools/display_emu/avi_check.py" "$HERE/boot.cmd"
mkimage -A arm -O linux -T script -C none -n "dsm232 usb boot" -d "$HERE/boot.cmd" boot.scr

# boot.cmd loads uInitrd at 0x5000000 and boot.scr at 0x6000000: keep the ramdisk below 16MB
size=$(stat -c %s uInitrd)
[ "$size" -lt $((0x1000000)) ] || { echo "uInitrd is $size bytes, over 16MB" >&2; exit 1; }
echo "built: $OUT/uInitrd ($size bytes) $OUT/boot.scr"
