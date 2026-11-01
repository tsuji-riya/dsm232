#!/bin/bash
# Runs inside the container (repo mounted at /work): kernel, Alpine initramfs, then out/dsm232-usb.img
set -euo pipefail
cd "$(dirname "$0")/.."
linux-7.2/build.sh /linux-src/linux
alpine/build.sh

rm -rf out
mkdir -p out/usb
cp linux-7.2/uImage alpine/out/uInitrd alpine/out/boot.scr out/usb/
cp alpine/out/rootfs.tar.gz out/
# boot.cmd loads uImage at 0x4000000 and uInitrd at 0x5000000: each must stay below 16MB
[ "$(stat -c %s out/usb/uImage)" -lt $((0x1000000)) ] || { echo "uImage over 16MB" >&2; exit 1; }

# 512MB image, MBR: partition 1 = FAT16 63MB from 1MB (fatload usb 0:1), partition 2 = ext4 root
# (448MB, the Alpine tree; boot.cmd passes root=/dev/sda2). Built without root/loop devices.
img=out/dsm232-usb.img
truncate -s 63M out/part.img
mkfs.vfat -F 16 -n DSM232 -h 2048 out/part.img >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -i out/part.img out/usb/* ::
truncate -s 448M out/root.img
# files owned by root in the file system: chown only inside fakeroot, which mke2fs -d then sees
fakeroot sh -c 'chown -R 0:0 alpine/out/rootfs && mke2fs -q -t ext4 -L dsm232root -d alpine/out/rootfs out/root.img'
truncate -s 512M "$img"
printf 'label: dos\nstart=2048, size=129024, type=6, bootable\nstart=131072, type=83\n' | sfdisk -q "$img"
dd if=out/part.img of="$img" bs=1M seek=1 conv=notrunc status=none
dd if=out/root.img of="$img" bs=1M seek=64 conv=notrunc,sparse status=none
rm out/part.img out/root.img
MTOOLS_SKIP_CHECK=1 mdir -i "$img@@1M" ::
echo "USB image: $img"
