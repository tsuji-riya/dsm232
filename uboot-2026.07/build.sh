#!/bin/bash
# Fetch U-Boot v2026.07, apply the CNC1800L/DSM-232 patch and build u-boot.bin
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../../u-boot-src}
[ -d "$SRC/.git" ] || git clone --depth 1 --branch v2026.07 https://github.com/u-boot/u-boot "$SRC"
cd "$SRC"
git -c user.name=build -c user.email=build@localhost am --3way "$HERE"/patches/*.patch
make dsm232_defconfig
make -j"$(nproc)" CROSS_COMPILE=arm-linux-gnueabi-
cp u-boot.bin "$HERE/u-boot.bin"
ls -l "$HERE/u-boot.bin"
