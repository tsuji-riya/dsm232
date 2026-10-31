#!/bin/bash
# Fetch Linux v7.2, apply the CNC1800L/DSM-232 patch and build uImage (zImage + appended DTB).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${1:-$HERE/../../linux-src}
[ -d "$SRC/.git" ] || git clone --depth 1 --branch v7.2 https://github.com/torvalds/linux "$SRC"
cd "$SRC"
git am --abort 2>/dev/null || true
git reset -q --hard v7.2  # rerun-safe: drop previously applied patches, keep build output
git -c user.name=build -c user.email=build@localhost am --3way "$HERE"/patches/*.patch
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
make cnc1800l_defconfig
# Kconfig silently drops symbols that no longer exist; fail instead of building a kernel without HDMI console
for s in VFP FB_SIMPLE FRAMEBUFFER_CONSOLE VT_CONSOLE BLK_DEV_INITRD \
	USB_EHCI_HCD_PLATFORM USB_OHCI_HCD_PLATFORM USB_STORAGE BLK_DEV_SD EXT4_FS VFAT_FS \
	NET INET PACKET CFG80211 ATH6KL_SDIO MMC_DW_PLTFM PWRSEQ_SIMPLE GPIO_GENERIC_PLATFORM FW_LOADER_COMPRESS_ZSTD; do
	grep -qx "CONFIG_$s=y" .config || { echo "CONFIG_$s missing in .config" >&2; exit 1; }
done
make -j"$(nproc)" zImage dtbs
cat arch/arm/boot/zImage arch/arm/boot/dts/celestial/cnc1800l-dsm232.dtb > "$HERE/zImage-dtb"
mkimage -A arm -O linux -T kernel -C none -a 0x8000 -e 0x8000 \
	-n "Linux-7.2 cnc1800l" -d "$HERE/zImage-dtb" "$HERE/uImage"
echo "built: $HERE/uImage"
