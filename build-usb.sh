#!/bin/sh
# Build everything in Docker. Result: out/dsm232-usb.img (write it to a USB stick) and out/usb/ (the same files).
set -eu
cd "$(dirname "$0")"
docker build -t dsm232-build - < docker/Dockerfile
docker run --rm -v "$PWD:/work" -w /work -u "$(id -u):$(id -g)" -e HOME=/tmp dsm232-build docker/build-all.sh
