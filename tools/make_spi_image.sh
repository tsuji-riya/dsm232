#!/bin/bash
# Build signed boot images with the vendor "insecure" signing tool.
#   make_spi_image.sh <signing_tool_dir> <miniloader_file> <u-boot.bin> [outdir]
# Parameters via env (defaults = vendor second_param.txt):
#   ML_SIZE=0xb000  SECOND_ENTRY=0x80000  SECOND_SIZE=0x5FF00  SECOND_EXEC=0x2000000
#   DDR0..DDR5 (DDRCfgParameter[0..5])  NAND_BLK=0x20000  BADBLK=1  FLASH_CFG=0x8b  DUAL=1  EXT0=0x2 EXT1=0xe
# WARNING: DDR* must be taken from the real device's SPI dump (param block at
# file offset 0xB500 of the stock image). Wrong values will hang DDR init.
set -euo pipefail
TOOL=$(realpath "$1"); ML=$(realpath "$2"); UB=$(realpath "$3"); OUT=${4:-$PWD/out}
mkdir -p "$OUT"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$TOOL"/mk_nonsec_image "$TOOL"/insecure_key.pem "$TOOL"/sign_sha256.sh "$W"/
cp "$W"/sign_sha256.sh "$W"/sign.sh; chmod +x "$W"/*
cp "$ML" "$W"/miniloader.bin; cp "$UB" "$W"/u-boot.bin; cp "$UB" "$W"/u-boot2.bin
cat > "$W"/param.txt <<P
${ML_SIZE:-0xb000}
${SECOND_ENTRY:-0x80000}
${SECOND_SIZE:-0x5FF00}
${SECOND_EXEC:-0x2000000}
${DDR0:-0x00001500}
${DDR1:-0x87b820b1}
${DDR2:-0xb6514255}
${DDR3:-0x3c3c3c3c}
${DDR4:-0x28182818}
${DDR5:-0x7200c379}
${NAND_BLK:-0x20000}
${BADBLK:-0x1}
${FLASH_CFG:-0x8b}
${DUAL:-0x1}
${EXT0:-0x2}
${EXT1:-0xe}
P
( cd "$W" && ./mk_nonsec_image miniloader.bin param.txt u-boot.bin u-boot2.bin insecure_key.pem )
cp "$W"/signed_miniloader.bin "$W"/signed_u-boot.bin "$W"/signed_u-boot2.bin "$W"/flash_image.bin "$OUT"/
ls -l "$OUT"
