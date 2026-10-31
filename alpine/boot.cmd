# DSM-232: boot Linux + Alpine initramfs from USB (FAT, partition 1) with the vendor U-Boot 2011.06.
# RAM: 0x4000000 uImage (<16MB) / 0x5000000 uInitrd (<16MB) / 0x6000000 boot.scr / 0xc000000 HDMI framebuffer
echo "== DSM-232 USB boot =="
# start HDMI 1080p60 (mode 16; the vendor "1080P" mode 7 is interlaced) RGB565 with a cleared 0xc000000 buffer; must match the DTS framebuffer
# override from the U-Boot prompt: setenv hdmimode 14; run bootcmd (only 1920x1080 modes 6/7/12-16 match the DTS)
# vendor hush re-parses any line with $ after substitution, so an empty "${x}" vanishes and test misbehaves:
# compare as x${var} = xVALUE
if test x${hdmimode} = x; then setenv hdmimode 16; fi
mw.w 0x6100000 0 1
logo ${hdmimode} 2 0x6100000 1 1 0 0
# The vendor hdmi.bin only knows modes up to 1080i: for 14/15/16 its AVI InfoFrame says VIC 4/3/1 with BT.601.
# Rewrite it (SiI TX AV page 0x80400400, reg r at +4r): YCbCr444 + underscan, BT.709 16:9, IT content, real VIC.
setenv avifix 'mw.l 0x804004f8 30; mw.l 0x8040050c ${avisum}; mw.l 0x80400510 52; mw.l 0x80400514 a8; mw.l 0x80400518 80; mw.l 0x8040051c ${avivic}; mw.l 0x80400520 0; mw.l 0x804004f8 33'
if test x${hdmimode} = x16; then setenv avivic 10; setenv avisum e5; run avifix; fi
if test x${hdmimode} = x15; then setenv avivic 1f; setenv avisum d6; run avifix; fi
if test x${hdmimode} = x14; then setenv avivic 22; setenv avisum d3; run avifix; fi
# A/B test: setenv hdcpoff 1 -> stop the HDCP encryption hdmi.bin authenticates (SiI HDCP_CTRL 0x72:0x0f);
# after boot nothing services the HDCP link any more
if test x${hdcpoff} = x1; then mw.l 0x8040003c 0; fi
fatload usb 0:1 0x4000000 uImage
fatload usb 0:1 0x5000000 uInitrd
# appended to the DT bootargs (earlycon console=ttyS0,115200n8 mem=137M); last console= becomes /dev/console
setenv bootargs console=tty1
# use the ramdisk in place: U-Boot would otherwise move it above Linux's 137MB
setenv initrd_high 0xffffffff
bootm 0x4000000 0x5000000
