#!/usr/bin/env bash
# Builds out/Kali-A2Core-TWRP.zip, a zip that TWRP can install.
# Needs the results of build-pmos.sh (out/boot.img, work/pmos/rootfs.*) and of
# build-kali-rootfs.sh (work/kali-root). Must run as root (loop mounts).
#
# The disk image has the same layout pmbootstrap produces for this phone:
#   GPT | p1 FAT32 "pmOS_boot" | p2 ext4 "pmOS_root" (= the Kali rootfs)
# The postmarketOS initramfs inside boot.img finds both partitions by label, even when
# the whole image sits inside one Android partition (it maps the "subpartitions" with kpartx),
# and on the first boot it grows p2 to fill the partition.
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work out
exec > >(tee -a work/twrp-zip.log) 2>&1

ROOT="$PWD/work/kali-root"
BOOTIMG="$PWD/out/boot.img"
ZIP="$PWD/out/Kali-A2Core-TWRP.zip"
IMG_BOOT="$PWD/work/twrp-boot.fat"
IMG_ROOT="$PWD/work/twrp-root.ext4"
IMG_DISK="$PWD/work/twrp-disk.img"
MNT_SRC="$PWD/work/twrp-mnt-src"
MNT_DST="$PWD/work/twrp-mnt-dst"

PMOS_RAW="$PWD/work/pmos/rootfs.raw"
[ -s "$PMOS_RAW" ] || PMOS_RAW="$PWD/work/pmos/rootfs.img"

[ -d "$ROOT/etc" ] || { echo "ERROR: Kali rootfs $ROOT not found"; exit 1; }
[ -s "$BOOTIMG" ] || { echo "ERROR: $BOOTIMG not found"; exit 1; }
[ -s "$PMOS_RAW" ] || { echo "ERROR: pmOS image not found in work/pmos"; exit 1; }

apt-get install -y gdisk dosfstools e2fsprogs fdisk python3 || true

cleanup() {
  umount "$MNT_SRC" 2>/dev/null || true
  umount "$MNT_DST" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$MNT_SRC" "$MNT_DST"

# ---- p1: pmOS_boot (FAT32), content copied from the pmOS image's own boot partition ----
file "$PMOS_RAW" || true
read -r B_START B_SIZE < <(sfdisk -J "$PMOS_RAW" | python3 -c 'import json,sys
p = json.load(sys.stdin)["partitiontable"]["partitions"][0]
print(p["start"], p["size"])')
mount -o ro,loop,offset=$((B_START*512)),sizelimit=$((B_SIZE*512)) "$PMOS_RAW" "$MNT_SRC"
ls -la "$MNT_SRC"
# boot.img and System.map are big and not needed on the partition (the kernel + initramfs are in boot.img)
BOOT_USED_MB=$(du -sm --exclude=boot.img --exclude=System.map "$MNT_SRC" | cut -f1)
BOOT_MB=$(( BOOT_USED_MB * 125 / 100 + 16 ))
[ "$BOOT_MB" -ge 64 ] || BOOT_MB=64
truncate -s "${BOOT_MB}M" "$IMG_BOOT"
mkfs.vfat -F 32 -n pmOS_boot "$IMG_BOOT"
mount -o loop "$IMG_BOOT" "$MNT_DST"
( cd "$MNT_SRC" && tar --exclude=./boot.img --exclude=./System.map -cf - . ) \
  | tar -C "$MNT_DST" -xf - --no-same-owner --no-same-permissions
ls -la "$MNT_DST"
sync
umount "$MNT_DST"
umount "$MNT_SRC"

# ---- p2: pmOS_root (ext4), the Kali rootfs ----
# Kept small on purpose: the initramfs grows it to the size of the target partition on the first boot.
USED_MB=$(du -sm --apparent-size "$ROOT" | cut -f1)
ROOT_MB=$(( USED_MB * 120 / 100 + 128 ))
truncate -s "${ROOT_MB}M" "$IMG_ROOT"
mkfs.ext4 -F -q -L pmOS_root -d "$ROOT" "$IMG_ROOT"
e2fsck -fn "$IMG_ROOT" || echo "::warning::e2fsck reported problems in the Kali root image"

# ---- GPT disk image: 1 MiB gap | p1 | p2 | 1 MiB for the backup GPT ----
TOTAL_MB=$(( 1 + BOOT_MB + ROOT_MB + 1 ))
truncate -s "${TOTAL_MB}M" "$IMG_DISK"
sgdisk --clear "$IMG_DISK"
sgdisk -n "1:2048:+${BOOT_MB}M" -t 1:EF00 -c 1:pmOS_boot "$IMG_DISK"
P2_START=$(( 2048 * (1 + BOOT_MB) ))
sgdisk -n "2:${P2_START}:0" -t 2:8305 -c 2:pmOS_root "$IMG_DISK"
sgdisk -p "$IMG_DISK"
dd if="$IMG_BOOT" of="$IMG_DISK" bs=1M seek=1 conv=notrunc
dd if="$IMG_ROOT" of="$IMG_DISK" bs=1M seek=$(( 1 + BOOT_MB )) conv=notrunc
rm -f "$IMG_BOOT" "$IMG_ROOT"

# sanity check: both partitions must carry the labels the pmOS initramfs looks for
for off in 2048 "$P2_START"; do
  L=$(losetup -f --show -o $(( off * 512 )) "$IMG_DISK")
  blkid "$L" || true
  losetup -d "$L"
done
[ "$(sfdisk -J "$IMG_DISK" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["partitiontable"]["partitions"]))')" = 2 ] \
  || { echo "ERROR: disk image does not have exactly 2 partitions"; exit 1; }

# ---- the zip ----
BOOT_BYTES=$(stat -c %s "$BOOTIMG")
echo "boot.img is $(( BOOT_BYTES / 1048576 )) MB; the disk image is $TOTAL_MB MB (boot ${BOOT_MB} MB + root ${ROOT_MB} MB)"
if [ "$BOOT_BYTES" -gt 33554432 ]; then
  echo "::warning title=boot.img size::boot.img is $(( BOOT_BYTES / 1048576 )) MB. The TWRP device tree says the BOOT partition is 32 MB, so the installer will refuse to flash it if that is true."
fi
rm -f "$ZIP"
python3 scripts/mkzip.py "$ZIP" "$BOOTIMG" "$IMG_DISK" scripts/twrp-update-binary.sh
rm -f "$IMG_DISK"
ls -la out
