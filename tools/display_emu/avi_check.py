# Verify the AVI InfoFrame bytes written by alpine/boot.cmd: checksum per hdmimode and the expected VIC.
import re, sys
s = open(sys.argv[1] if len(sys.argv) > 1 else 'alpine/boot.cmd').read()
db = {a: int(v, 16) for a, v in re.findall(r'mw\.l 0x(80400510|80400514|80400518|80400520) (\w+)', s)}
want = {'16': 16, '15': 31, '14': 34}
for mode, vic, csum in re.findall(r'"\$\{hdmimode\}" = (\d+); then setenv avivic (\w+); setenv avisum (\w+)', s):
    vic, csum = int(vic, 16), int(csum, 16)
    total = 0x82 + 0x02 + 0x0d + csum + db['80400510'] + db['80400514'] + db['80400518'] + vic + db['80400520']
    assert total & 0xff == 0, 'mode %s: bad checksum' % mode
    assert want.pop(mode) == vic, 'mode %s: wrong VIC %d' % (mode, vic)
assert not want, 'missing modes %s' % want
print('boot.cmd AVI InfoFrames OK')
