# Emulate vendor U-Boot "logo <mode> 2 ..." and log every MMIO access.
import sys, struct, re, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from edid import EDID
from unicorn import *
from unicorn.arm_const import *

IMG = open(sys.argv[1], 'rb').read()
MODE = sys.argv[2]
OUT = open(sys.argv[3], 'w')
BASE = 0x2000000
APPS = 0x3000000                     # relocated copy of the appended apps (dvu.bin/hdmi.bin)
STOP = 0x1000                        # return sentinel
MMIO = [(0x80000000, 0x01000000), (0xa0000000, 0x01000000), (0xb0000000, 0x04000000), (0xfff00000, 0x00100000)]

mu = Uc(UC_ARCH_ARM, UC_MODE_ARM)
mu.mem_map(0, 0x10000000)            # all DRAM (256MB)
mu.mem_write(BASE, IMG[:0x4e450])    # text+data; BSS (0x204e450..) stays zero
mu.mem_write(APPS, IMG[0x55c90:])
mu.mem_write(BASE + 0x50, struct.pack('<I', APPS - BASE))
for a, s in MMIO:
    mu.mem_map(a, s)

regs = {}                            # register file model: reads return last write
def rd_hook(uc, access, addr, size, value, ud):
    v = regs.get(addr, 0)
    v = POLL.get(addr, lambda v: v)(v)
    uc.mem_write(addr, v.to_bytes(4, 'little')[:size])
    OUT.write('R%d %08x -> %08x  @%08x\n' % (size * 8, addr, v, uc.reg_read(UC_ARM_REG_PC)))
def wr_hook(uc, access, addr, size, value, ud):
    regs[addr] = value & ((1 << (size * 8)) - 1)
    if addr == 0x804003cc: ddc_cmd(regs[addr])
    OUT.write('W%d %08x <- %08x  @%08x\n' % (size * 8, addr, regs[addr], uc.reg_read(UC_ARM_REG_PC)))
DDC = {'fifo': b''}
def ddc_fifo_cnt(v): return len(DDC['fifo'])
def ddc_data(v):
    b = DDC['fifo'][:1]; DDC['fifo'] = DDC['fifo'][1:]; return b[0] if b else 0
POLL = {0x80400024: lambda v: v | 0x07,    # SiI SYS_STAT: P_STABLE | HPD | RSEN (monitor attached)
        0x804003d4: ddc_fifo_cnt,          # DDC_FIFOCNT
        0x804003d0: ddc_data,              # DDC_DATA
        0x804003c8: lambda v: 0}           # DDC_STATUS: idle, no error
def ddc_cmd(val):
    if val == 0x02:                        # sequential read
        seg = regs.get(0x804003b8, 0); off = regs.get(0x804003bc, 0)
        n = regs.get(0x804003c0, 0) | (regs.get(0x804003c4, 0) << 8)
        DDC['fifo'] = EDID[seg * 256 + off: seg * 256 + off + n]
    elif val == 0x09:
        DDC['fifo'] = b''
for a, s in MMIO:
    mu.hook_add(UC_HOOK_MEM_READ, rd_hook, begin=a, end=a + s - 1)
    mu.hook_add(UC_HOOK_MEM_WRITE, wr_hook, begin=a, end=a + s - 1)

def cstr(a):
    return bytes(mu.mem_read(a, 256)).split(b'\0')[0].decode('latin1')
def printf_hook(uc):
    fmt = cstr(uc.reg_read(UC_ARM_REG_R0))
    args = [uc.reg_read(r) for r in (UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3)]
    sp = uc.reg_read(UC_ARM_REG_SP)
    args += list(struct.unpack('<8I', bytes(uc.mem_read(sp, 32))))
    it = iter(args)
    s = re.sub(r'%[-0-9.]*l?([dxXusc%])', lambda m: '%' if m.group(1) == '%' else
               (cstr(next(it)) if m.group(1) == 's' else str(next(it)) if m.group(1) in 'du' else
                chr(next(it) & 0xff) if m.group(1) == 'c' else '%x' % next(it)), fmt)
    OUT.write('# printf: ' + s.rstrip('\n') + '\n')
def ret(uc, val=0):
    uc.reg_write(UC_ARM_REG_R0, val)
    uc.reg_write(UC_ARM_REG_PC, uc.reg_read(UC_ARM_REG_LR))
STUBS = {0x200e014: lambda uc: (printf_hook(uc), ret(uc)),   # printf
         0x2000544: lambda uc: ret(uc)}                        # timer wait used by udelay
count = [0]
def code_hook(uc, addr, size, ud):
    count[0] += 1
    if addr in STUBS:
        STUBS[addr](uc)
    if count[0] > 50_000_000:
        OUT.write('# instruction limit at %08x\n' % addr); uc.emu_stop()
mu.hook_add(UC_HOOK_CODE, code_hook)

# argv strings + array
args = ['logo', MODE, '2', '6100000', '1', '1', '0', '0']
p = 0x7000000; ptrs = []
for a in args:
    mu.mem_write(p, a.encode() + b'\0'); ptrs.append(p); p += 32
mu.mem_write(0x7001000, struct.pack('<%dI' % len(ptrs), *ptrs))
mu.reg_write(UC_ARM_REG_R0, 0x204dc8c); mu.reg_write(UC_ARM_REG_R1, 0)
mu.reg_write(UC_ARM_REG_R2, len(args)); mu.reg_write(UC_ARM_REG_R3, 0x7001000)
mu.reg_write(UC_ARM_REG_SP, 0x7f00000); mu.reg_write(UC_ARM_REG_LR, STOP)
mu.reg_write(UC_ARM_REG_R8, 0x7800000)
# standalone apps reach U-Boot via gd->jt; every gd word points at a fake table whose entry i is stub JT+4*i
JTAB, JT = 0x7900000, 0x7a00000
mu.mem_write(0x7800000, struct.pack('<64I', *([JTAB] * 64)))
mu.mem_write(JTAB, struct.pack('<64I', *[JT + 4 * i for i in range(64)]))
JTNAMES = ['get_version','getc','tstc','putc','puts','printf','install_hdlr','free_hdlr','malloc','free',
           'udelay','get_timer','vprintf','do_reset','getenv','setenv','simple_strtoul','strict_strtoul',
           'simple_strtol','strcmp','i2c_write','i2c_read']
heap = [0x7c00000]
def jt_hook(uc, addr, size, ud):
    i = (addr - JT) // 4
    a = [uc.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3)]
    sp = uc.reg_read(UC_ARM_REG_SP); a4 = struct.unpack('<I', bytes(uc.mem_read(sp, 4)))[0]
    n = JTNAMES[i] if i < len(JTNAMES) else 'jt%d' % i
    if n == 'printf':
        printf_hook(uc); return ret(uc)
    if n == 'puts':
        OUT.write('# puts: %s\n' % cstr(a[0]).rstrip()); return ret(uc)
    if n in ('i2c_write', 'i2c_read'):
        # i2c_xxx(chip, addr, alen, buf, len)
        if n == 'i2c_read':
            data = I2C.get((a[0], a[1]), bytes(a4))
            uc.mem_write(a[3], data[:a4].ljust(a4, b'\0'))
        data = bytes(uc.mem_read(a[3], a4))
        OUT.write('I2C %s chip=%02x reg=%02x len=%d data=%s\n' % (n[4:], a[0], a[1], a4, data.hex()))
        return ret(uc, 0)
    if n == 'malloc':
        p = heap[0]; heap[0] += (a[0] + 15) & ~15; return ret(uc, p)
    if i == 45:                                # vendor memset(ptr, c, n)
        uc.mem_write(a[0], bytes([a[1] & 0xff]) * a[2]); return ret(uc, a[0])
    if i == 46:                                # vendor TVE0/TVE1 register write (id, reg, val, ...)
        OUT.write('TVE%d reg=%02x val=%x (%x)\n' % (a[0], a[1], a[2], a[3])); return ret(uc, 0)
    if n in ('udelay', 'free', 'install_hdlr', 'free_hdlr'):
        return ret(uc, 0)
    if n == 'simple_strtoul':
        txt = cstr(a[0]); base = a[2] or (16 if txt.lower().startswith('0x') else 10)
        return ret(uc, int(re.match(r'(0x)?[0-9a-fA-F]*', txt).group(0) or '0', base) if txt else 0)
    if n == 'get_timer':
        count[1] += 1000; return ret(uc, count[1])
    OUT.write('# jt call %s(%x, %x, %x, %x)\n' % (n, *a)); ret(uc, 0)
I2C = {}
count.append(0)
mu.hook_add(UC_HOOK_CODE, jt_hook, begin=JT, end=JT + 0x100)
try:
    mu.emu_start(0x20042dc, STOP)
    OUT.write('# returned r0=%d after %d insns\n' % (mu.reg_read(UC_ARM_REG_R0), count[0]))
except UcError as e:
    OUT.write('# FAULT %s at pc=%08x lr=%08x\n' % (e, mu.reg_read(UC_ARM_REG_PC), mu.reg_read(UC_ARM_REG_LR)))
OUT.close()
