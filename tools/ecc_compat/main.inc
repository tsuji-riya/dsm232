
/* vendor correct(): locate the failing bit from the 24 bit code difference */
static int vendor_locate(uint32_t diff, int *byte_, int *bit_)
{
	if ((((diff >> 1) ^ diff) & 0x555555) != 0x555555)
		return 0;
	*bit_ = ((diff >> 19) & 1) | ((diff >> 20) & 2) | ((diff >> 21) & 4);
	*byte_ = ((diff >> 9) & 0x100) | (diff & 0x80) | ((diff << 1) & 0x40) |
		 ((diff << 2) & 0x20) | ((diff << 3) & 0x10) |
		 ((diff >> 12) & 0x08) | ((diff >> 11) & 0x04) |
		 ((diff >> 10) & 0x02) | ((diff >> 9) & 0x01);
	return 1;
}

int main(void)
{
	unsigned char buf[512], e0[3], e1[3];

	srand(1);
	for (int i = 0; i < 512; i++)
		buf[i] = rand();
	for (int so = 0; so < 2; so++) {
		int ok = 0, tot = 0;

		ecc_sw_hamming_calculate(buf, 512, e0, so);
		for (int by = 0; by < 512; by++)
			for (int b = 0; b < 8; b++) {
				int fb, fbit;
				uint32_t d;

				buf[by] ^= 1 << b;
				ecc_sw_hamming_calculate(buf, 512, e1, so);
				buf[by] ^= 1 << b;
				d = (e0[0] ^ e1[0]) | ((e0[1] ^ e1[1]) << 8) |
				    ((e0[2] ^ e1[2]) << 16);
				if (vendor_locate(d, &fb, &fbit) && fb == by && fbit == b)
					ok++;
				tot++;
			}
		printf("sm_order=%d: vendor decoder locates %d/%d single-bit errors of Linux soft Hamming(512)\n",
		       so, ok, tot);
	}
	return 0;
}
