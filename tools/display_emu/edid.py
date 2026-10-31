# Typical 1080p HDMI TV EDID: base block (preferred 1080p60) + CEA-861 extension (YCbCr support, HDMI VSDB).
def dtd(clk_khz, ha, hb, hfp, hsw, va, vb, vfp, vsw):
    c = clk_khz // 10
    return bytes([c & 0xff, c >> 8, ha & 0xff, hb & 0xff, ((ha >> 8) << 4) | (hb >> 8),
                  va & 0xff, vb & 0xff, ((va >> 8) << 4) | (vb >> 8), hfp & 0xff, hsw & 0xff,
                  ((vfp & 0xf) << 4) | (vsw & 0xf), ((hfp >> 8) << 6) | ((hsw >> 8) << 4) | ((vfp >> 4) << 2) | (vsw >> 4),
                  0x40, 0x84, 0x63, 0, 0, 0x1e])
def csum(b):
    return b + bytes([(-sum(b)) & 0xff])
P1080 = dtd(148500, 1920, 280, 88, 44, 1080, 45, 4, 5)
base = bytes([0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]) + bytes([0x4c, 0x2d, 0x01, 0x0c, 0, 0, 0, 0, 1, 0x1e, 1, 3,
       0x80, 0x66, 0x39, 0x78, 0x0a]) + bytes([0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54]) + \
       bytes([0xbd, 0xef, 0x80]) + bytes([0x01, 0x01] * 8) + P1080 + \
       dtd(74250, 1280, 370, 110, 40, 720, 30, 5, 5) + \
       bytes([0, 0, 0, 0xfd, 0, 0x18, 0x4b, 0x1a, 0x51, 0x17, 0, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20]) + \
       bytes([0, 0, 0, 0xfc, 0]) + b'TEST TV\n     ' + bytes([1])
assert len(base) == 127, len(base)
base = csum(base)
vics = [16, 31, 4, 19, 5, 20, 3, 2, 34]
db = bytes([0x40 | len(vics)]) + bytes(vics)                         # video data block
db += bytes([0x23, 0x09, 0x07, 0x07])                                 # audio: LPCM 2ch
db += bytes([0x83, 0x01, 0x00, 0x00])                                 # speaker allocation
db += bytes([0x65, 0x03, 0x0c, 0x00, 0x10, 0x00])                     # HDMI VSDB, phys addr 1.0.0.0
ext = bytes([2, 3, 4 + len(db), 0x70]) + db                          # underscan, audio, YCbCr444+422
ext = ext.ljust(127, b'\0')
EDID = base + csum(ext)
assert len(EDID) == 256 and sum(EDID[:128]) % 256 == 0 and sum(EDID[128:]) % 256 == 0
