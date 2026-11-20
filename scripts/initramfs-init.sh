#!/bin/busybox sh
# Minimal initramfs for Kali on Galaxy A2 Core (v13).
# Root is LABEL=kali_root (big root on USERDATA) if present and bootable, else LABEL=pmOS_root (old SYSTEM root).
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
# The bootloader gives the kernel its own cmdline ("console=ram"), so /dev/console may not work.
# Write straight to the screen (tty0) when possible, and never let a failed redirect kill init.
exec 0</dev/null
for c in /dev/tty0 /dev/console /dev/kmsg; do
  if [ -c "$c" ] && ( : > "$c" ) 2>/dev/null; then exec 1>"$c" 2>&1; break; fi
done
echo "[kali-rd] start, kernel $(uname -r)"
echo "[kali-rd] partitions:"; cat /proc/partitions


# USB ethernet gadget straight from the initramfs, so the phone is visible over USB even without a working screen
usb_gadget() {
  mount -t configfs none /sys/kernel/config 2>/dev/null
  G=/sys/kernel/config/usb_gadget/kali
  [ -d "$G" ] && return 0
  mkdir -p "$G" || return 1
  cd "$G" || return 1
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
  w=0
  while [ "$w" -lt 20 ] && [ -z "$(ls /sys/class/udc 2>/dev/null)" ]; do
    # dwc3 here is in usb-role-switch mode: nothing in the DT switches it, so ask for device mode
    for r in /sys/class/usb_role/*/role; do [ -e "$r" ] && echo device > "$r" 2>/dev/null; done
    sleep 1; w=$((w+1))
  done
  echo "[kali-rd] usb_role: $(ls /sys/class/usb_role 2>/dev/null) udc: $(ls /sys/class/udc 2>/dev/null)"
  echo "$(ls /sys/class/udc | head -n1)" > UDC || return 1
  ip addr add 172.16.42.1/24 dev usb0
  ip link set usb0 up
  cd /
}
if usb_gadget; then echo "[kali-rd] USB gadget up (172.16.42.1)"; else echo "[kali-rd] USB gadget FAILED"; fi
cd /

fail() {
  echo "[kali-rd] ERROR: $1"
  echo "---- /proc/partitions"; cat /proc/partitions
  echo "---- blkid"; blkid
  echo "[kali-rd] halting here so you can read this (photo the screen)"
  while true; do sleep 60; done
}

# try to mount $1 as the root filesystem; succeed only if it has a usable /sbin/init
try_root() {
  [ -n "$1" ] && [ -b "$1" ] || return 1
  echo "[kali-rd] trying $1: $(blkid "$1" 2>&1)"
  if mount -t ext4 -o rw,noatime "$1" /sysroot 2>/dev/null; then
    if [ -x /sysroot/sbin/init ]; then return 0; fi
    echo "[kali-rd] $1 mounted but has no /sbin/init"
    umount /sysroot 2>/dev/null
  else
    echo "[kali-rd] cannot mount $1"
  fi
  return 1
}

# wait up to 30 s for a root partition to appear; prefer kali_root, fall back to pmOS_root
GOT=""
n=0
while [ "$n" -lt 30 ]; do
  for L in kali_root pmOS_root; do
    D=$(findfs LABEL=$L 2>/dev/null)
    if [ -n "$D" ] && try_root "$D"; then GOT="$D"; break; fi
  done
  [ -n "$GOT" ] && break
  n=$((n+1))
  sleep 1
done
if [ -z "$GOT" ] && try_root /dev/mmcblk0p18; then GOT=/dev/mmcblk0p18; fi
[ -n "$GOT" ] || fail "no bootable root (kali_root or pmOS_root) found"
echo "[kali-rd] root device: $GOT, switching to Kali"
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
exec switch_root /sysroot /sbin/init
fail "switch_root failed"
