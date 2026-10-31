# DSM-232: boot Linux + Alpine initramfs from USB (FAT, partition 1) with the vendor U-Boot 2011.06.
# RAM: 0x4000000 uImage (<16MB) / 0x5000000 uInitrd (<16MB) / 0x6000000 boot.scr / 0xc000000 HDMI framebuffer
echo "== DSM-232 USB boot =="
# start HDMI 1080p (mode 7, largest; must match the DTS framebuffer) RGB565 with a cleared (black) 0xc000000 buffer; the 1x1 "picture" is a black pixel
mw.w 0x6100000 0 1
logo 7 2 0x6100000 1 1 0 0
fatload usb 0:1 0x4000000 uImage
fatload usb 0:1 0x5000000 uInitrd
# appended to the DT bootargs (earlycon console=ttyS0,115200n8 mem=137M); last console= becomes /dev/console
setenv bootargs console=tty1
# use the ramdisk in place: U-Boot would otherwise move it above Linux's 137MB
setenv initrd_high 0xffffffff
bootm 0x4000000 0x5000000
