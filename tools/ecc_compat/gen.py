import sys
src=open(sys.argv[1]).read().split('\n')
body='\n'.join(src[23:443])           # calculate/correct part of ecc-sw-hamming.c
hdr='''#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define EXPORT_SYMBOL(x)
#define EBADMSG 74
#define EIO 5
#define EINVAL 22
#define __maybe_unused
#define likely(x) (x)
#define unlikely(x) (x)
#define BIT(n) (1U<<(n))
typedef uint32_t u32; typedef uint8_t u8; typedef uint64_t u64; typedef uint16_t u16; typedef uint32_t __le32;
#define le32_to_cpu(x) (x)
#define cpu_to_le32(x) (x)
#define __swab32(x) __builtin_bswap32(x)
#define swab32 __builtin_bswap32
#define be32_to_cpu(x) __builtin_bswap32(x)
#define fallthrough
#define pr_err(...)
'''
for name in ('nand_ecc_sw_hamming_calculate','nand_ecc_sw_hamming_correct'):
    i=body.find('int '+name)
    if i>=0:
        j=body.find('\n}\n',i)+3
        body=body[:i]+body[j:]
print(hdr+body+open(sys.argv[2]).read())
