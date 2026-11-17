#!/usr/bin/env bash
# Builds a Kali arm64 root filesystem and merges in the kernel modules + firmware
# from the postmarketOS image built by build-pmos.sh. Must run as root.
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work out
exec > >(tee -a work/kali.log) 2>&1
TOOLS="${TOOLS:-kali-linux-core}"
UI="${UI:-none}"
ROOT="$PWD/work/kali-root"

cleanup() {
  umount -R "$ROOT/dev" "$ROOT/sys" "$ROOT/proc" 2>/dev/null || true
  umount work/pmos-mnt 2>/dev/null || true
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# tools for reading/writing Android sparse images and ext4 images
apt-get install -y android-sdk-libsparse-utils e2fsprogs fdisk || true

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
mkdir -p /etc/dnsmasq.d /etc/NetworkManager/conf.d
printf 'interface=usb0\nbind-dynamic\ndhcp-range=172.16.42.2,172.16.42.10,255.255.255.0,12h\n' > /etc/dnsmasq.d/usb.conf
printf '[keyfile]\nunmanaged-devices=interface-name:usb0\n' > /etc/NetworkManager/conf.d/10-usb0.conf
systemctl enable NetworkManager ssh usb-gadget.service dnsmasq || true

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
tar -C "$ROOT" --numeric-owner --xattrs -cpf - . | pigz -6 > out/kali-rootfs.tar.gz

# ---- flashable image: ext4 labelled pmOS_root (what pmOS' initramfs looks for), as Android sparse ----
# Flash it like the pmOS rootfs: heimdall flash --USERDATA kali-rootfs-sparse.img
( set +e
  USED=$(du -sm --apparent-size "$ROOT" | cut -f1)
  SIZE=$(( USED * 125 / 100 + 400 ))
  truncate -s "${SIZE}M" work/kali-root.img
  mkfs.ext4 -F -q -L pmOS_root -d "$ROOT" work/kali-root.img \
    && img2simg work/kali-root.img out/kali-rootfs-sparse.img \
    && echo "built flashable sparse image (${SIZE} MB)"
) || true
ls -la out
