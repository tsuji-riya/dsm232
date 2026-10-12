#!/bin/bash
# Check whether the vendor CNC1800L HW-ECC code format equals the Linux software
# Hamming (512 byte step) format. Usage: run.sh <linux-source-tree>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LINUX=${1:?linux tree}
python3 "$HERE/gen.py" "$LINUX/drivers/mtd/nand/ecc-sw-hamming.c" "$HERE/main.inc" > "$HERE/h.c"
gcc -O1 -w -o "$HERE/h" "$HERE/h.c"
"$HERE/h"
