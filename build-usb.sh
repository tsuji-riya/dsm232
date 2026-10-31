#!/bin/sh
# Build everything in Docker. Result: out/dsm232-usb.img (write it to a USB stick) and out/usb/ (the same files).
set -eu
cd "$(dirname "$0")"
docker build -t dsm232-build - < docker/Dockerfile
# kernel source in a named volume: it has case-colliding paths (xt_DSCP.h / xt_dscp.h) that break on macOS/Windows host filesystems
docker run --rm -v "$PWD:/work" -v dsm232-linux-src:/linux-src -w /work -u "$(id -u):$(id -g)" -e HOME=/tmp dsm232-build docker/build-all.sh
