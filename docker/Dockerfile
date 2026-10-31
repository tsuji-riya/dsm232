# Build environment for the DSM-232 USB image (kernel + Alpine initramfs + FAT image). Built without context.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	gcc-arm-linux-gnueabi gcc libc6-dev make bc bison flex libssl-dev python3 \
	git ca-certificates curl u-boot-tools cpio gzip \
	dosfstools mtools fdisk \
	&& rm -rf /var/lib/apt/lists/*
