# DSM-232: boot Linux + Alpine initramfs from USB (FAT, partition 1) with the vendor U-Boot 2011.06.
# RAM: 0x4000000 uImage (<16MB) / 0x5000000 uInitrd (<16MB) / 0x6000000 boot.scr / 0xc000000 HDMI framebuffer
echo "== DSM-232 USB boot =="
# vendor hush runs a script line by line and re-parses any line with $ after substitution, so an empty
# "${x}" vanishes and test misbehaves: one-line ifs only, compare as x${var} = xVALUE
# HDMI: Linux sets up 1080p60 itself (cnc1800l-display). Fallback to the vendor path: setenv hdmi uboot; run bootcmd
# vendor path: start HDMI with "logo" (mode from $hdmimode, default 16 = 1080p60; only 1920x1080 modes
# 6/7/12-16 match the DTS) RGB565 with a cleared 0xc000000 buffer, and tell Linux to keep it
if test x${hdmimode} = x; then setenv hdmimode 16; fi
# The vendor hdmi.bin only knows modes up to 1080i: for 14/15/16 its AVI InfoFrame says VIC 4/3/1 with BT.601.
# Rewrite it (SiI TX AV page 0x80400400, reg r at +4r): YCbCr444 + underscan, BT.709 16:9, IT content, real VIC.
setenv avifix 'mw.l 0x804004f8 30; mw.l 0x8040050c ${avisum}; mw.l 0x80400510 52; mw.l 0x80400514 a8; mw.l 0x80400518 80; mw.l 0x8040051c ${avivic}; mw.l 0x80400520 0; mw.l 0x804004f8 33'
setenv avimode 'if test x${hdmimode} = x16; then setenv avivic 10; setenv avisum e5; run avifix; fi; if test x${hdmimode} = x15; then setenv avivic 1f; setenv avisum d6; run avifix; fi; if test x${hdmimode} = x14; then setenv avivic 22; setenv avisum d3; run avifix; fi'
# A/B test: setenv hdcpoff 1 -> stop the HDCP encryption hdmi.bin authenticates (SiI HDCP_CTRL 0x72:0x0f);
# after boot nothing services the HDCP link any more
setenv ubootdisp 'mw.w 0x6100000 0 1; logo ${hdmimode} 2 0x6100000 1 1 0 0; run avimode; if test x${hdcpoff} = x1; then mw.l 0x8040003c 0; fi; setenv dispargs cnc1800l_display.skip=1'
setenv dispargs
if test x${hdmi} = xuboot; then run ubootdisp; fi
fatload usb 0:1 0x4000000 uImage
fatload usb 0:1 0x5000000 uInitrd
# root file system: ext4 on partition 2 of the stick by default (the initramfs /init switches to it, and
# stays in RAM if it is missing after 20s); setenv rootdev ram -> run from the initramfs only
if test x${rootdev} = x; then setenv rootdev /dev/sda2; fi
# appended to the DT bootargs (earlycon console=ttyS0,115200n8 mem=137M); last console= becomes /dev/console.
# $extraargs: more kernel arguments
setenv bootargs console=tty1 root=${rootdev} ${dispargs} ${extraargs}
# use the ramdisk in place: U-Boot would otherwise move it above Linux's 137MB
setenv initrd_high 0xffffffff
bootm 0x4000000 0x5000000
