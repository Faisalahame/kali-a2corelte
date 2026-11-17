#!/usr/bin/env bash
# Builds the close-to-mainline Exynos 7870 kernel + initramfs + boot.img for samsung-a2corelte
# using postmarketOS' pmbootstrap (it already knows this phone's boot image format).
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/pmos out
exec > >(tee -a work/pmos.log) 2>&1
DEVICE=samsung-a2corelte

python3 -m pip install --user --break-system-packages pmbootstrap
export PATH="$HOME/.local/bin:$PATH"
pmbootstrap --version

pmbootstrap -y config device "$DEVICE"
pmbootstrap -y config ui none
pmbootstrap -y config user kali
pmbootstrap -y config hostname kali-a2core
pmbootstrap -y install --password kali

rm -rf /tmp/pmos-export
pmbootstrap -y export /tmp/pmos-export
ls -laL /tmp/pmos-export

BOOT=$(ls /tmp/pmos-export/boot.img* | head -n1)
cp -L "$BOOT" out/boot.img
cp -L "/tmp/pmos-export/${DEVICE}.img" work/pmos/rootfs.img
ls -la out work/pmos
