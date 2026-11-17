#!/usr/bin/env bash
# Builds a Kali arm64 root filesystem, merges in the kernel modules + firmware from the
# postmarketOS image built by build-pmos.sh, and packs everything into ONE TWRP-flashable zip.
# Must run as root.
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work out
exec > >(tee -a work/kali.log) 2>&1
TOOLS="${TOOLS:-kali-linux-core}"
UI="${UI:-none}"
ROOT="$PWD/work/kali-root"
OUTZIP="$PWD/out/kali-a2corelte-twrp.zip"

cleanup() {
  # kill daemons that apt postinst scripts started inside the chroot (they keep the mounts busy)
  for p in /proc/[0-9]*; do
    r=$(readlink "$p/root" 2>/dev/null || true)
    case "$r" in "$ROOT"|"$ROOT"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
  done
  sleep 1
  # unmount each bind mount separately and lazily, otherwise "busy" mounts stay mounted
  for m in dev sys proc; do umount -R -l "$ROOT/$m" 2>/dev/null || true; done
  umount work/pmos-mnt 2>/dev/null || true
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# tools for reading Android sparse images, building ext4 images and the zip
apt-get install -y android-sdk-libsparse-utils e2fsprogs fdisk zip unzip || true

rm -rf "$ROOT"
curl -fsSL https://archive.kali.org/archive-keyring.gpg -o /usr/share/keyrings/kali-archive-keyring.gpg
[ -e /usr/share/debootstrap/scripts/kali-rolling ] || ln -s sid /usr/share/debootstrap/scripts/kali-rolling

debootstrap --arch=arm64 --variant=minbase \
  --components=main,contrib,non-free,non-free-firmware \
  --keyring=/usr/share/keyrings/kali-archive-keyring.gpg \
  --include=systemd-sysv,dbus,udev,kmod,ca-certificates \
  kali-rolling "$ROOT" http://http.kali.org/kali

cp /usr/bin/qemu-aarch64-static "$ROOT/usr/bin/" || true
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
mount -t proc proc "$ROOT/proc"
mount --rbind /sys "$ROOT/sys"
mount --rbind /dev "$ROOT/dev"

cat > "$ROOT/setup.sh" <<'SETUP'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
echo kali-a2core > /etc/hostname
echo "127.0.1.1 kali-a2core" >> /etc/hosts
echo "LABEL=pmOS_root / ext4 defaults,noatime 0 1" > /etc/fstab

# The keyring downloaded on the host lacks Kali's newest signing key, so the first
# "apt-get update" can't verify the repo. Install the current keyring package first.
apt-get update || true
apt-get install -y kali-archive-keyring || true
apt-get update || true
apt-get install -y --no-install-recommends network-manager wpasupplicant openssh-server \
  iw iproute2 iputils-ping sudo nano less dnsmasq locales usbutils
apt-get install -y firmware-brcm80211 bluez bluez-firmware || apt-get install -y bluez || true
apt-get install -y ${TOOLS}
if [ "${UI}" = "phosh" ]; then
  apt-get install -y phosh phoc squeekboard foot || true
  systemctl enable phosh.service || true
fi

useradd -m -s /bin/bash kali || true
for g in sudo audio video plugdev netdev input dialout bluetooth; do
  getent group "$g" >/dev/null && usermod -aG "$g" kali || true
done
echo 'kali:kali' | chpasswd
echo 'root:kali' | chpasswd

# USB networking so you can always ssh in (phone = 172.16.42.1, PC gets DHCP)
cat > /usr/local/sbin/usb-gadget.sh <<'GADGET'
#!/bin/sh
modprobe libcomposite 2>/dev/null
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
G=/sys/kernel/config/usb_gadget/kali
[ -d "$G" ] && exit 0
mkdir -p "$G" && cd "$G"
echo 0x18d1 > idVendor
echo 0xd001 > idProduct
mkdir -p strings/0x409
echo kali-a2corelte > strings/0x409/serialnumber
echo Kali > strings/0x409/manufacturer
echo "Kali A2 Core" > strings/0x409/product
mkdir -p configs/c.1/strings/0x409
echo ecm > configs/c.1/strings/0x409/configuration
mkdir -p functions/ecm.usb0
ln -s functions/ecm.usb0 configs/c.1/
echo "$(ls /sys/class/udc | head -n1)" > UDC
ip addr add 172.16.42.1/24 dev usb0
ip link set usb0 up
GADGET
chmod +x /usr/local/sbin/usb-gadget.sh
cat > /etc/systemd/system/usb-gadget.service <<'UNIT'
[Unit]
Description=USB ethernet gadget
Before=dnsmasq.service network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-gadget.sh
[Install]
WantedBy=multi-user.target
UNIT
# first boot: grow the root filesystem to fill the whole partition it was flashed to
cat > /etc/systemd/system/resize-root.service <<'RESIZE'
[Unit]
Description=Grow root filesystem to fill its partition (first boot only)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'resize2fs "$(findmnt -n -o SOURCE /)" && systemctl disable resize-root.service'
[Install]
WantedBy=multi-user.target
RESIZE
mkdir -p /etc/dnsmasq.d /etc/NetworkManager/conf.d
printf 'interface=usb0\nbind-dynamic\ndhcp-range=172.16.42.2,172.16.42.10,255.255.255.0,12h\n' > /etc/dnsmasq.d/usb.conf
printf '[keyfile]\nunmanaged-devices=interface-name:usb0\n' > /etc/NetworkManager/conf.d/10-usb0.conf
systemctl enable NetworkManager ssh usb-gadget.service dnsmasq resize-root.service || true

apt-get clean
rm -rf /var/lib/apt/lists/* /setup.sh
SETUP
chmod +x "$ROOT/setup.sh"
chroot "$ROOT" env TOOLS="$TOOLS" UI="$UI" /setup.sh

# ---- merge kernel modules + firmware from the postmarketOS image ----
# pmbootstrap exports this phone's rootfs as an Android *sparse* ext4 image (flash_sparse=true,
# flashed with heimdall), so it has no partition table. Convert it back to a raw image first.
IMG=work/pmos/rootfs.img
file "$IMG" || true
if [ "$(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
  echo "pmOS rootfs is an Android sparse image -> simg2img"
  simg2img "$IMG" work/pmos/rootfs.raw
  IMG=work/pmos/rootfs.raw
fi
file "$IMG" || true
mkdir -p work/pmos-mnt
sfdisk -d "$IMG" || true
PMOS_OK=""
# 1) the image is a bare ext4 filesystem
if mount -o ro,loop "$IMG" work/pmos-mnt 2>/dev/null; then
  if [ -d work/pmos-mnt/etc ]; then PMOS_OK=1; else umount work/pmos-mnt; fi
fi
# 2) the image is a whole disk: mount each partition by byte offset, keep the one with /etc
if [ -z "$PMOS_OK" ]; then
  while read -r START SIZE; do
    if mount -o ro,loop,offset=$((START*512)),sizelimit=$((SIZE*512)) "$IMG" work/pmos-mnt 2>/dev/null; then
      if [ -d work/pmos-mnt/etc ]; then PMOS_OK=1; break; fi
      umount work/pmos-mnt
    fi
  done < <(sfdisk -J "$IMG" 2>/dev/null | python3 -c 'import json,sys
try:
  for p in json.load(sys.stdin)["partitiontable"]["partitions"]: print(p["start"], p["size"])
except Exception: pass')
fi
[ -n "$PMOS_OK" ] || { echo "ERROR: could not mount the pmOS rootfs image"; exit 1; }
ls work/pmos-mnt
for d in lib usr/lib; do
  [ -d "work/pmos-mnt/$d/modules" ] && mkdir -p "$ROOT/usr/lib/modules" && cp -a "work/pmos-mnt/$d/modules/." "$ROOT/usr/lib/modules/"
  [ -d "work/pmos-mnt/$d/firmware" ] && mkdir -p "$ROOT/usr/lib/firmware" && cp -an "work/pmos-mnt/$d/firmware/." "$ROOT/usr/lib/firmware/"
done
for d in etc/modules-load.d etc/modprobe.d; do
  [ -d "work/pmos-mnt/$d" ] && mkdir -p "$ROOT/$d" && cp -an "work/pmos-mnt/$d/." "$ROOT/$d/"
done
for v in "$ROOT"/usr/lib/modules/*; do [ -d "$v" ] && depmod -b "$ROOT" "$(basename "$v")"; done
ls "$ROOT/usr/lib/modules" || true

rm -f "$ROOT/etc/resolv.conf" "$ROOT/usr/bin/qemu-aarch64-static"
cleanup
# nothing may be mounted inside the rootfs any more (otherwise the image would contain the host's /sys, /proc, /dev)
findmnt -R "$ROOT" || true
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev"

# ---- raw ext4 image labelled pmOS_root (the label pmOS' initramfs looks for) ----
USED=$(du -sm --apparent-size --one-file-system "$ROOT" | cut -f1)
SIZE=$(( USED * 125 / 100 + 400 ))
truncate -s "${SIZE}M" work/kali-root.img
mkfs.ext4 -F -q -L pmOS_root -d "$ROOT" work/kali-root.img
e2fsck -fn work/kali-root.img || true

# ---- the TWRP-flashable zip ----
Z=work/twrp
rm -rf "$Z"
mkdir -p "$Z/META-INF/com/google/android"
echo "# dummy: update-binary is a shell script" > "$Z/META-INF/com/google/android/updater-script"
cat > "$Z/META-INF/com/google/android/update-binary" <<'UPDATER'
#!/sbin/sh
# Kali Linux for Samsung Galaxy A2 Core - TWRP installer
# Writes boot.img to BOOT and the Kali root filesystem to SYSTEM.
OUTFD=/proc/self/fd/$2
ZIPFILE="$3"

ui_print() { echo "ui_print $1" > "$OUTFD"; echo "ui_print" > "$OUTFD"; }
abort() { ui_print " "; ui_print "ERROR: $1"; ui_print "Aborting."; exit 1; }

# find a partition node by name (Samsung uses upper case names)
part() {
  for n in "$1" "$(echo "$1" | tr 'A-Z' 'a-z')"; do
    for d in /dev/block/platform/*/by-name /dev/block/by-name; do
      if [ -e "$d/$n" ]; then readlink -f "$d/$n"; return 0; fi
    done
  done
  return 1
}
# size in bytes of a block device
size_of() {
  b=$(basename "$1")
  s=$(cat "/sys/class/block/$b/size" 2>/dev/null)
  echo $(( ${s:-0} * 512 ))
}
# uncompressed size of a file inside the zip
zip_size() { unzip -l "$ZIPFILE" "$1" 2>/dev/null | grep " $1\$" | awk '{print $1}'; }

ui_print "======================================="
ui_print "   Kali Linux  -  Galaxy A2 Core"
ui_print "======================================="
ui_print "Device: $(getprop ro.product.device)"

BOOT=$(part BOOT) || abort "BOOT partition not found"
SYS=$(part SYSTEM) || abort "SYSTEM partition not found"
ui_print "BOOT   : $BOOT"
ui_print "SYSTEM : $SYS"

IMG_SZ=$(zip_size kali-root.img)
BOOT_IMG_SZ=$(zip_size boot.img)
SYS_SZ=$(size_of "$SYS")
BOOT_SZ=$(size_of "$BOOT")
[ -n "$IMG_SZ" ] && [ -n "$BOOT_IMG_SZ" ] || abort "zip is incomplete (kali-root.img / boot.img missing)"
ui_print "rootfs image $((IMG_SZ/1048576)) MB -> SYSTEM $((SYS_SZ/1048576)) MB"
ui_print "boot image   $((BOOT_IMG_SZ/1024)) KB -> BOOT   $((BOOT_SZ/1024)) KB"
[ "$IMG_SZ" -le "$SYS_SZ" ] || abort "SYSTEM partition is too small for the Kali image"
[ "$BOOT_IMG_SZ" -le "$BOOT_SZ" ] || abort "boot.img does not fit in the BOOT partition. Nothing was written."

ZREAL=$(readlink -f "$ZIPFILE")
case "$ZREAL" in
  /system/*|/system_root/*) abort "Do not keep this zip on /system. Copy it to the SD card or /sdcard." ;;
esac

# back up the current boot image (so you can go back to Android)
BK=""
for d in /external_sd /sdcard1 /sdcard /tmp; do
  if [ -d "$d" ] && [ -w "$d" ]; then BK="$d/Kali-backup"; break; fi
done
mkdir -p "$BK"
dd if="$BOOT" of="$BK/boot-original.img" bs=1048576 2>/dev/null || abort "could not back up BOOT"
ui_print "Backed up old BOOT to $BK/boot-original.img"
[ "$BK" = "/tmp/Kali-backup" ] && ui_print "WARNING: backup is only in /tmp (lost on reboot) - no writable storage found"

ui_print " "
ui_print "Writing Kali root filesystem to SYSTEM (a few minutes)..."
umount /system 2>/dev/null; umount /system_root 2>/dev/null; umount "$SYS" 2>/dev/null
unzip -p "$ZIPFILE" kali-root.img | dd of="$SYS" bs=1048576 || abort "writing the rootfs failed - SYSTEM is now broken, re-flash this zip"
sync
blkid "$SYS" 2>/dev/null | grep -q pmOS_root || abort "rootfs verification failed (label pmOS_root not found) - re-flash this zip"
ui_print "Root filesystem written."

# grow the filesystem to fill the partition (best effort; Kali also does it on first boot)
if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
  e2fsck -fy "$SYS" >/dev/null 2>&1
  resize2fs "$SYS" >/dev/null 2>&1 && ui_print "Filesystem grown to fill SYSTEM."
fi

ui_print "Writing boot image to BOOT..."
unzip -o -q "$ZIPFILE" boot.img -d /tmp || abort "could not extract boot.img"
dd if=/tmp/boot.img of="$BOOT" bs=1048576 || abort "writing BOOT failed - restore $BK/boot-original.img"
sync
A=$(md5sum /tmp/boot.img | cut -d' ' -f1)
B=$(dd if="$BOOT" bs=1048576 count=$(( (BOOT_IMG_SZ + 1048575) / 1048576 )) 2>/dev/null | head -c "$BOOT_IMG_SZ" | md5sum | cut -d' ' -f1)
rm -f /tmp/boot.img
[ "$A" = "$B" ] || abort "BOOT verification failed - restore $BK/boot-original.img"
ui_print "Boot image verified."

ui_print " "
ui_print "Done. Reboot to system."
ui_print "First boot takes a while. Log in on the phone or over USB:"
ui_print "  ssh kali@172.16.42.1   (user kali, password kali)"
exit 0
UPDATER
chmod 755 "$Z/META-INF/com/google/android/update-binary"
cp out/boot.img "$Z/boot.img"
cp work/kali-root.img "$Z/kali-root.img"
rm -f "$OUTZIP"
( cd "$Z" && zip -q -r -9 "$OUTZIP" META-INF boot.img kali-root.img )
unzip -l "$OUTZIP"
# keep only the flashable zip in out/ (the workflow uploads out/*)
mv out/boot.img work/boot.img.built
ls -la out
