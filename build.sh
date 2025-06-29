#!/bin/bash
set -e

CROSS_COMPILE=arm-linux-gnueabihf-
ARCH=arm
JOBS=$(nproc)
BUILD_DIR=/root/build

# 1. カーネルビルド
cd /root/linux

# ← ここで config を反映
cp /root/running_kernel_config .config
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE zImage -j$JOBS

# 2. busybox（変更なし）
cd /root/busybox
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE defconfig
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j$JOBS
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE install

# 3. initramfs 構築
mkdir -p $BUILD_DIR/initramfs/{dev,proc,sys}
cp -r /root/busybox/_install/* $BUILD_DIR/initramfs/

cat <<EOF > $BUILD_DIR/initramfs/init
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
exec /bin/sh
EOF

chmod +x $BUILD_DIR/initramfs/init

cd $BUILD_DIR/initramfs
find . | cpio -o --format=newc | gzip > ../initramfs.cpio.gz

# 4. 成果物
cp /root/linux/arch/arm/boot/zImage $BUILD_DIR/
