#!/bin/sh
# Emulate the vendor U-Boot "logo <mode> 2 ..." (+ its hdmi.bin) from dump/nand.bin and log every
# display/HDMI register access. Needs: python3, pip install unicorn capstone.
# Usage: tools/display_emu/run.sh [mode ...]   -> out/display_emu/trace<mode>.txt + register diff
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../../out/display_emu}
mkdir -p "$OUT"
# vendor U-Boot (+ appended dvu.bin/hdmi.bin) is at NAND 0x20000, linked at 0x02000000
python3 -I -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(d[0x20000:0xa0000])" \
	"$HERE/../../dump/nand.bin" "$OUT/uboot.bin"
[ $# -gt 0 ] || set -- 5 7 14 15 16
for m in "$@"; do python3 -I "$HERE/run_logo.py" "$OUT/uboot.bin" "$m" "$OUT/trace$m.txt"; done
python3 -I "$HERE/final.py" "$OUT" "$@"
