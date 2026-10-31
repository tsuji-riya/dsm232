# Final register state per mode (last write wins) for DF/clock/HDMI, plus the final AVI infoframe.
import sys
def state(path):
    st = {}
    for l in open(path):
        if l.startswith('W'):
            f = l.split(); st[int(f[1], 16)] = int(f[3], 16)
    return st
modes = sys.argv[1:]
S = {m: state(sys.argv[1] + '/trace%s.txt' % m) for m in modes[1:]}
modes = modes[1:]
keys = sorted(set().union(*S.values()))
def name(a):
    if 0x80400000 <= a < 0x80401000:
        o = a - 0x80400000
        return ('P2:%02x' % ((o - 0x400) // 4)) if o >= 0x400 else ('72:%02x' % (o // 4))
    return '%08x' % a
print('%-10s' % 'reg' + ''.join('%10s' % ('m' + m) for m in modes))
for k in keys:
    vals = [S[m].get(k) for m in modes]
    if len(set(vals)) > 1 or 'all' in sys.argv[0:0]:
        print('%-10s' % name(k) + ''.join('%10s' % ('-' if v is None else '%x' % v) for v in vals))
for m in modes:
    avi = [S[m].get(0x80400400 + 4 * r, 0) for r in range(0x40, 0x51)]
    print('mode %s AVI: type=%02x ver=%d len=%d DB1=%02x DB2=%02x DB3=%02x VIC=%d PR=%d' % (m, avi[0], avi[1], avi[2], avi[4], avi[5], avi[6], avi[7], avi[8]))
