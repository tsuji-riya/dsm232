# Run a U-Boot script through the vendor U-Boot 2011.06's own hush parser (as "source" does) in Unicorn.
# test/setenv/run/mw/echo are the real vendor commands; usb/fatload/bootm/logo/md are stubbed and logged.
# Usage: run_script.py uboot.bin script.cmd [var=value ...]   (vars are setenv'd first, like a saved env)
import sys, struct, re
from unicorn import *
from unicorn.arm_const import *

IMG = open(sys.argv[1], 'rb').read()
SCRIPT = open(sys.argv[2], 'rb').read()
PRESET = [a.split('=', 1) for a in sys.argv[3:]]
BASE, STOP = 0x2000000, 0x1000
PRINTF, PUTS = 0x200e014, 0x200dfc0
PARSE_STRING_OUTER, SET_DEFAULT_ENV = 0x2010f04, 0x200f428
MALLOC_START, MALLOC_END, MALLOC_BRK = 0x2050d14, 0x2050d18, 0x2050d1c
GD = 0x7800000

mu = Uc(UC_ARCH_ARM, UC_MODE_ARM)
mu.mem_map(0, 0x10000000)
mu.mem_write(BASE, IMG[:0x4e450])                  # text + data, BSS zero
# apply the image's R_ARM_ABS32 relocations (.rel.dyn + .dynsym, overlaid by BSS at 0x4e450) for load
# offset 0, as relocate_code would: e.g. find_cmd's __u_boot_cmd_start/end literals are 0 in the image
o = 0x4e450
while True:
    r_off, info = struct.unpack_from('<2I', IMG, o)
    if info & 0xff not in (0x02, 0x17) or not BASE <= r_off < BASE + 0x4e450:
        break
    o += 8
dynsym = o
for x in range(0x4e450, dynsym, 8):
    r_off, info = struct.unpack_from('<2I', IMG, x)
    if info & 0xff == 0x02:
        val = struct.unpack_from('<I', IMG, dynsym + 16 * (info >> 8) + 4)[0]
        a = struct.unpack_from('<I', IMG, r_off - BASE)[0]
        mu.mem_write(r_off, struct.pack('<I', val + a))
for a, s in ((0x80000000, 0x1000000), (0xa0000000, 0x1000000), (0xb0000000, 0x4000000)):
    mu.mem_map(a, s)
mu.mem_write(MALLOC_START, struct.pack('<3I', 0x8000000, 0x9000000, 0x8000000))
out = []
CONSOLE = []
def log(s): out.append(s); print(s)
UART = 0x801f1000                                 # ns16550, reg-shift 2
def wr(uc, acc, addr, size, val, ud):
    if addr == UART:
        CONSOLE.append(chr(val & 0xff))
    elif not UART <= addr < UART + 0x20:
        log('MMIO W%d %08x <- %x' % (size * 8, addr, val))
def rd(uc, acc, addr, size, val, ud):
    if addr == UART + 0x14:
        uc.mem_write(addr, b'\x60')                    # LSR: THRE | TEMT
mu.hook_add(UC_HOOK_MEM_WRITE, wr, begin=0x80000000, end=0xbfffffff)
mu.hook_add(UC_HOOK_MEM_READ, rd, begin=UART, end=UART + 0x1f)

def cstr(a, n=512): return bytes(mu.mem_read(a, n)).split(b'\0')[0].decode('latin1')
def ret(uc, v=0):
    uc.reg_write(UC_ARM_REG_R0, v); uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
def fmt(uc):
    f = cstr(uc.reg_read(UC_ARM_REG_R0))
    args = [uc.reg_read(r) for r in (UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3)]
    args += list(struct.unpack('<8I', bytes(uc.mem_read(uc.reg_read(UC_ARM_REG_SP), 32))))
    it = iter(args)
    return re.sub(r'%[-0-9.]*l?([dxXusc%])', lambda m: '%' if m.group(1) == '%' else
                  (cstr(next(it)) if m.group(1) == 's' else str(next(it)) if m.group(1) in 'du' else
                   chr(next(it) & 0xff) if m.group(1) == 'c' else '%x' % next(it)), f)
STUB = {}
def argv(uc):
    argc, av = uc.reg_read(UC_ARM_REG_R2), uc.reg_read(UC_ARM_REG_R3)
    return [cstr(struct.unpack('<I', bytes(uc.mem_read(av + 4 * i, 4)))[0]) for i in range(argc)]
# stub selected commands by their cmd_tbl_t entry: name, maxargs, repeatable, cmd, usage, help
for name in (b'usb', b'fatload', b'bootm', b'logo', b'md'):
    for m in re.finditer(re.escape(name) + b'\0', IMG):
        for i in range(0, 0x4e000, 4):
            e = struct.unpack_from('<6I', IMG, i)
            if e[0] == BASE + m.start() and e[1] < 64 and BASE <= e[3] < BASE + 0x4e000:
                STUB[e[3]] = name.decode()
def code(uc, addr, size, ud):
    if addr == PRINTF:
        CONSOLE.append(fmt(uc)); return ret(uc)
    if addr == PUTS:
        CONSOLE.append(cstr(uc.reg_read(UC_ARM_REG_R0))); return ret(uc)
    if addr in STUB:
        log('CMD %s' % ' '.join(argv(uc))); return ret(uc, 0)
mu.hook_add(UC_HOOK_CODE, code)

def call(fn, *args):
    for r, v in zip((UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3), args):
        mu.reg_write(r, v)
    mu.reg_write(UC_ARM_REG_SP, 0x7f00000); mu.reg_write(UC_ARM_REG_LR, STOP); mu.reg_write(UC_ARM_REG_R8, GD)
    try:
        mu.emu_start(fn, STOP, count=200_000_000)
    except UcError as e:
        log('FAULT %s pc=%08x lr=%08x' % (e, mu.reg_read(UC_ARM_REG_PC), mu.reg_read(UC_ARM_REG_LR)))
    if mu.reg_read(UC_ARM_REG_PC) != STOP:
        log('STOPPED at pc=%08x (no return)' % mu.reg_read(UC_ARM_REG_PC))
    return mu.reg_read(UC_ARM_REG_R0)
def run(text):
    p = 0x7000000
    mu.mem_write(p, text + b'\0')
    return call(PARSE_STRING_OUTER, p, 2)       # FLAG_PARSE_SEMICOLON, as do_source()

mu.mem_write(GD + 0x34, struct.pack('<I', 0x0ff00000))   # gd->relocaddr: mw refuses writes above it
call(SET_DEFAULT_ENV, 0)
for k, v in PRESET:
    run(('setenv %s %s\n' % (k, v)).encode())
CONSOLE.clear()
run(SCRIPT)
for c in ''.join(CONSOLE).splitlines():
    if c.strip(): log('OUT %s' % c)
