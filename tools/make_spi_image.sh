#!/bin/bash
# Build signed boot images with the vendor "insecure" signing tool.
#   make_spi_image.sh <signing_tool_dir> <miniloader_file> <u-boot.bin> [outdir]
# Parameters via env. Defaults = the param block of a real DSM-232 A1 (dump/spi.bin
# offset 0xB500), not the GPL second_param.txt, which differs (entry 0x80000, size
# 0x5FF00, DDR0 0x1500, DDR2 0xb6514255, dual boot on):
#   ML_SIZE=0xb000  SECOND_ENTRY=0x20000 (NAND)  SECOND_SIZE=0x7FF00  SECOND_EXEC=0x2000000
#   DDR0..DDR5 (DDRCfgParameter[0..5])  NAND_BLK=0x20000  BADBLK=1  FLASH_CFG=0x8b  DUAL=0  EXT0=0x2 EXT1=0xe
# WARNING: check DDR* against your own unit's SPI dump. Wrong values will hang DDR init.
# Replacing only U-Boot does not need this script nor an SPI write: see tools/uboot_slot.py.
set -euo pipefail
TOOL=$(realpath "$1"); ML=$(realpath "$2"); UB=$(realpath "$3"); OUT=${4:-$PWD/out}
mkdir -p "$OUT"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$TOOL"/mk_nonsec_image "$TOOL"/insecure_key.pem "$TOOL"/sign_sha256.sh "$W"/
cp "$W"/sign_sha256.sh "$W"/sign.sh; chmod +x "$W"/*
cp "$ML" "$W"/miniloader.bin; cp "$UB" "$W"/u-boot.bin; cp "$UB" "$W"/u-boot2.bin
cat > "$W"/param.txt <<P
${ML_SIZE:-0xb000}
${SECOND_ENTRY:-0x20000}
${SECOND_SIZE:-0x7FF00}
${SECOND_EXEC:-0x2000000}
${DDR0:-0x00001400}
${DDR1:-0x87b820b1}
${DDR2:-0xb641c365}
${DDR3:-0x3c3c3c3c}
${DDR4:-0x28182818}
${DDR5:-0x7200c379}
${NAND_BLK:-0x20000}
${BADBLK:-0x1}
${FLASH_CFG:-0x8b}
${DUAL:-0x0}
${EXT0:-0x2}
${EXT1:-0xe}
P
( cd "$W" && ./mk_nonsec_image miniloader.bin param.txt u-boot.bin u-boot2.bin insecure_key.pem )
cp "$W"/signed_miniloader.bin "$W"/signed_u-boot.bin "$W"/signed_u-boot2.bin "$W"/flash_image.bin "$OUT"/
ls -l "$OUT"
