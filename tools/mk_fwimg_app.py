#!/usr/bin/env python3
"""Wrap a .tar.gz as an "app" image for the vendor fwimg (usage: mk_fwimg_app.py app.tar.gz factory.img).

fwimg (vendor Linux, run by usbupg -f at boot for cameo_factory/factory.img on a USB stick) checks only:
magic, header CRC32, data CRC32 and "DSM232" in the name. For type 12 (app) it writes the data to
/mnt/jffs2/app.tar.gz, untars it into /mnt/jffs2 and runs /mnt/jffs2/app.sh as root.
Layout = U-Boot legacy header, but little-endian and another magic (as the vendor mkimg -T app writes it).
"""
import struct
import sys
import time
import zlib

MAGIC, OS_LINUX, ARCH_ARM, TYPE_APP, COMP_NONE = 0x70883967, 5, 2, 12, 0
HDR = struct.Struct("<7I4B32s")


def crc(b):
	"""CRC-32 table of zlib, but starting at 0 and without the final inversion (vendor crc32)."""
	return zlib.crc32(b, 0xFFFFFFFF) ^ 0xFFFFFFFF


def make(data, name=b"DSM232_App", stamp=None):
	stamp = int(time.time()) if stamp is None else stamp
	fields = [MAGIC, 0, stamp, len(data), 0, 0, crc(data), OS_LINUX, ARCH_ARM, TYPE_APP, COMP_NONE, name]
	fields[1] = crc(HDR.pack(*fields))
	return HDR.pack(*fields) + data


def check(img):
	"""What fwimg checks before it installs the image."""
	f = list(HDR.unpack_from(img))
	assert f[0] == MAGIC and f[9] == TYPE_APP and b"DSM232" in f[11]
	hcrc, f[1] = f[1], 0
	assert hcrc == crc(HDR.pack(*f))
	assert f[6] == crc(img[HDR.size:HDR.size + f[3]]) and len(img) == HDR.size + f[3]


if __name__ == "__main__":
	src, dst = sys.argv[1:3]
	img = make(open(src, "rb").read())
	check(img)
	open(dst, "wb").write(img)
