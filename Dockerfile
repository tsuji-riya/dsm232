FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
  build-essential \
  bc \
  u-boot-tools \
  libncurses-dev \
  bison \
  flex \
  libssl-dev \
  wget \
  git \
  cpio \
  unzip \
  rsync \
  gcc-arm-linux-gnueabihf \
  crossbuild-essential-armhf

WORKDIR /root