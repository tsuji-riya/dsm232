import sys
start = sys.argv[2] if len(sys.argv) > 2 else None
on = start is None
for l in open(sys.argv[1]):
    if not on:
        on = start in l
        if not on: continue
    if l[0] in 'RW' and l.split()[1].startswith('804'):
        a = int(l.split()[1], 16) - 0x80400000
        pg = 'FF' if a >= 0x1000 else ('P2' if a >= 0x400 else '72')
        reg = (a % 0x400) // 4 if pg != 'FF' else (a - 0x1000) // 4
        val = l.split()[3]
        if l[0] == 'W' or 'show_reads' in sys.argv:
            print('%s %s:%02x %s %s' % (l[0], pg, reg, '=' if l[0] == 'W' else '->', val[-2:]))
    elif l[0] in 'RW':
        if l[0] == 'W': print(l.rstrip())
    else:
        print(l.rstrip())
