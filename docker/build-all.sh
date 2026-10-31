#!/bin/bash
# Runs inside the container (repo mounted at /work): kernel, Alpine initramfs, then out/dsm232-usb.img
set -euo pipefail
cd "$(dirname "$0")/.."
linux-7.2/build.sh .cache/linux-src
alpine/build.sh

rm -rf out
mkdir -p out/usb
cp linux-7.2/uImage alpine/out/uInitrd alpine/out/boot.scr out/usb/
# boot.cmd loads uImage at 0x4000000 and uInitrd at 0x5000000: each must stay below 16MB
[ "$(stat -c %s out/usb/uImage)" -lt $((0x1000000)) ] || { echo "uImage over 16MB" >&2; exit 1; }

# 64MB image: MBR, partition 1 = FAT16 from 1MB (fatload usb 0:1). Built without root/loop devices.
img=out/dsm232-usb.img
truncate -s 63M out/part.img
mkfs.vfat -F 16 -n DSM232 -h 2048 out/part.img >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -i out/part.img out/usb/* ::
truncate -s 64M "$img"
printf 'label: dos\nstart=2048, type=6, bootable\n' | sfdisk -q "$img"
dd if=out/part.img of="$img" bs=1M seek=1 conv=notrunc status=none
rm out/part.img
MTOOLS_SKIP_CHECK=1 mdir -i "$img@@1M" ::
echo "USB image: $img"
