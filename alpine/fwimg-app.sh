#!/bin/sh
# Runs as root in the vendor firmware whenever it boots with the stick plugged in: /etc/normalrc runs
# usbupg -f, which finds cameo_factory/factory.img on /dev/sda1; fwimg untars this file into /mnt/jffs2
# and runs it (docs/USB_BOOT_ALPINE.md 3.4).
# It arms a one-shot U-Boot bootcmd and reboots. U-Boot puts the old bootcmd back and saves it before it
# looks for boot.scr on USB storage devices 0-3 (a hub included), so the saved environment ends up as it
# was, and without the stick the vendor firmware boots as usual.
rm -f "$0"	# fwimg deletes it only after we return, and the reboot may come first
# trace every step on the console (UART), next to fwimg's "Installing App.."
exec 2>&1
set -x
mark=/mnt/usb/cameo_factory/armed
# $mark left from the last arming: that USB boot did not reach Linux on the stick (it deletes $mark).
# Stay in the vendor firmware instead of a reboot loop; the next power-on tries again.
if [ -e $mark ]; then rm -f $mark; sync; exit 0; fi
env=/dlink/env
cur=$($env get bootcmd)
# no bootcmd, already armed, or a value we cannot put in '...'
case $cur in '' | *dsmusb* | *"'"*) exit 1 ;; esac
# The vendor env tool copies the value into a 256-byte buffer: keep each value well below.
# The loop is in its own variable: if U-Boot cannot parse it, bootcmd itself still restores, saves and boots.
set -- "setenv bootcmd '$cur';saveenv;run dsmusb;run bootcmd" \
	'setenv dsmusb;saveenv;usb start;for d in 0 1 2 3;do if fatload usb $d:1 6000000 boot.scr;then setenv usbdev $d;source 6000000;fi;done;usb stop'
for v; do [ ${#v} -lt 240 ] || exit 1; done
touch $mark && sync || exit 1
# dsmusb first: a power cut between the two writes then leaves bootcmd unchanged.
# The vendor env tool always exits with 1, so check each write by reading it back.
$env set dsmusb "$2"
[ "$($env get dsmusb)" = "$2" ] || exit 1
$env set bootcmd "$1"
[ "$($env get bootcmd)" = "$1" ] || exit 1
sync
(sleep 2; reboot) &
