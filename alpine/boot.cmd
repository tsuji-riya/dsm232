# DSM-232: boot Linux + Alpine initramfs from USB (FAT, partition 1) with the vendor U-Boot 2011.06.
# RAM: 0x4000000 uImage (<16MB) / 0x5000000 uInitrd (<16MB) / 0x6000000 boot.scr
echo "== DSM-232 USB boot =="
# vendor hush runs a script line by line and re-parses any line with $ after substitution, so an empty
# "${x}" vanishes and test misbehaves: one-line ifs only, compare as x${var} = xVALUE
# $usbdev: the USB storage device boot.scr came from (set by the bootcmd that scans devices 0-3, e.g.
# behind a hub); 0 when boot.scr was loaded by hand
if test x${usbdev} = x; then setenv usbdev 0; fi
fatload usb ${usbdev}:1 0x4000000 uImage
fatload usb ${usbdev}:1 0x5000000 uInitrd
# root file system: the ext4 labelled dsm232root (partition 2 of the stick) by default, found by label
# because sdX depends on the other USB disks (the initramfs /init switches to it, and stays in RAM if it
# is missing after 20s); setenv rootdev ram -> run from the initramfs only
if test x${rootdev} = x; then setenv rootdev LABEL=dsm232root; fi
# appended to the DT bootargs (earlycon console=ttyS0,115200n8 mem=137M); last console= becomes /dev/console.
# $extraargs: more kernel arguments
setenv bootargs console=tty1 root=${rootdev} ${extraargs}
# use the ramdisk in place: U-Boot would otherwise move it above Linux's 137MB
setenv initrd_high 0xffffffff
bootm 0x4000000 0x5000000
