#!/usr/bin/env python3
"""U-Boot slot of the DSM-232 NAND (0x20000 and its copy at 0xa0000).

The miniloader parameter block (SPI 0xb500) loads 0x7ff00 bytes from NAND
0x20000. A slot is those bytes (U-Boot padded with 0x00) followed by an
RSA-2048 PKCS#1 v1.5 SHA-256 signature (256 bytes, 0x80000 in all). The
public modulus is at SPI 0x480 (big endian, e = 65537). Checked on the dumps
of a real unit: python3 tools/uboot_slot.py check dump/spi.bin dump/nand.bin

  check <spi.bin> <nand.bin>             verify both slots of a NAND dump
  verify <spi.bin> <slot.bin>            verify one slot image
  sign <spi.bin> <u-boot.bin> <key.pem> <slot.bin>
        pad, sign with openssl and write the slot only if it verifies
        against the device key in <spi.bin>
"""
import hashlib
import subprocess
import sys

BODY = 0x7FF00
SIG = 256
MOD_OFF = 0x480
SLOTS = (0x20000, 0xA0000)
# DER DigestInfo prefix of SHA-256 (PKCS#1 v1.5)
DIGESTINFO = bytes.fromhex("3031300d060960864801650304020105000420")


def modulus(spi):
    return int.from_bytes(spi[MOD_OFF:MOD_OFF + SIG], "big")


def verify(spi, slot):
    if len(slot) != BODY + SIG:
        return False
    n = modulus(spi)
    m = pow(int.from_bytes(slot[BODY:], "big"), 65537, n).to_bytes(SIG, "big")
    h = hashlib.sha256(slot[:BODY]).digest()
    pad = SIG - 3 - len(DIGESTINFO) - len(h)
    return m == b"\x00\x01" + b"\xff" * pad + b"\x00" + DIGESTINFO + h


def main(a):
    rd = lambda p: open(p, "rb").read()
    if len(a) == 3 and a[0] == "check":
        spi, nand = rd(a[1]), rd(a[2])
        ok = all(verify(spi, nand[o:o + BODY + SIG]) for o in SLOTS)
        print("slots 0x20000/0xa0000:", "OK" if ok else "BAD")
        return 0 if ok else 1
    if len(a) == 3 and a[0] == "verify":
        ok = verify(rd(a[1]), rd(a[2]))
        print("OK" if ok else "BAD")
        return 0 if ok else 1
    if len(a) == 5 and a[0] == "sign":
        spi, ub = rd(a[1]), rd(a[2])
        if len(ub) > BODY:
            sys.exit(f"u-boot.bin is {len(ub)} bytes, the slot holds {BODY}")
        body = ub + b"\x00" * (BODY - len(ub))
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", a[3]],
                             input=body, capture_output=True, check=True).stdout
        slot = body + sig
        if not verify(spi, slot):
            sys.exit("signature does not verify with the key in the SPI dump: "
                     "the miniloader would reject this slot, nothing written")
        open(a[4], "wb").write(slot)
        print(f"{a[4]}: {len(slot):#x} bytes, verified")
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
