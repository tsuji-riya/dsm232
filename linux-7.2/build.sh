#!/bin/bash
# Fetch Linux v7.2, apply the CNC1800L/DSM-232 patch and build uImage (zImage + appended DTB).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../../linux-src}
[ -d "$SRC/.git" ] || git clone --depth 1 --branch v7.2 https://github.com/torvalds/linux "$SRC"
cd "$SRC"
git -c user.name=build -c user.email=build@localhost am --3way "$HERE"/patches/*.patch
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
make cnc1800l_defconfig
make -j"$(nproc)" zImage dtbs
cat arch/arm/boot/zImage arch/arm/boot/dts/celestial/cnc1800l-dsm232.dtb > "$HERE/zImage-dtb"
mkimage -A arm -O linux -T kernel -C none -a 0x8000 -e 0x8000 \
	-n "Linux-7.2 cnc1800l" -d "$HERE/zImage-dtb" "$HERE/uImage"
echo "built: $HERE/uImage"
