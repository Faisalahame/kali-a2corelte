#!/sbin/sh
# Kali Linux for Samsung Galaxy A2 Core - ALL-IN-ONE TWRP installer
# Writes the Kali root filesystem (with the touch desktop) to USERDATA = the whole internal storage,
# and the small boot image to BOOT. Flash it FROM THE MICROSD CARD: the install erases the internal storage.
# The old Kali on SYSTEM (if any) is left alone and is the fallback if the new root cannot be mounted.
# Nothing is written until every check has passed.
OUTFD=/proc/self/fd/$2
ZIPFILE="$3"
LOCALZ=""

ui_print() { echo "ui_print $1" > "$OUTFD"; echo "ui_print" > "$OUTFD"; }
cleanup() { umount /tmp/kali-oldroot 2>/dev/null; umount /tmp/kali-newroot 2>/dev/null; [ -n "$LOCALZ" ] && rm -f "$LOCALZ" 2>/dev/null; }
abort() { ui_print " "; ui_print "ERROR: $1"; ui_print "Aborting."; cleanup; exit 1; }

part() {
  for n in "$1" "$(echo "$1" | tr 'A-Z' 'a-z')"; do
    for d in /dev/block/platform/*/by-name /dev/block/by-name; do
      if [ -e "$d/$n" ]; then readlink -f "$d/$n"; return 0; fi
    done
  done
  return 1
}
size_of() { b=$(basename "$1"); s=$(cat "/sys/class/block/$b/size" 2>/dev/null); echo $(( ${s:-0} * 512 )); }
file_size() { ls -l "$1" 2>/dev/null | awk '{print $5}'; }
# true if $1 is a writable directory on a real disk that is NOT the data partition
sd_dir() {
  [ -d "$1" ] && [ -w "$1" ] || return 1
  fsdev=$(df -P "$1" 2>/dev/null | tail -1 | awk '{print $1}')
  case "$fsdev" in /dev/*) ;; *) return 1 ;; esac
  [ "$(readlink -f "$fsdev")" != "$UD" ] || return 1
  return 0
}
free_kb() { df -P "$1" 2>/dev/null | tail -1 | awk '{print $4}'; }
md5_head() { dd if="$1" bs=1048576 count=$(( ($2 + 1048575) / 1048576 )) 2>/dev/null | head -c "$2" | md5sum | cut -d' ' -f1; }
mf() {
  if [ -n "$2" ]; then echo "$MF" | awk -v k="$1" -v n="$2" '$1==k && $2==n {print $3; exit}'
  else echo "$MF" | awk -v k="$1" '$1==k {print $2; exit}'; fi
}

ui_print "=============================================="
ui_print "  Kali Linux - Galaxy A2 Core - ALL-IN-ONE"
ui_print "=============================================="
DEV=$(getprop ro.product.device)
[ -n "$DEV" ] || DEV=$(getprop ro.build.product)
ui_print "Device: $DEV"
case "$DEV" in a2core*) ;; *) abort "this zip is only for the Galaxy A2 Core (a2corelte), found '$DEV'" ;; esac

BOOT=$(part BOOT) || abort "BOOT partition not found"
UD=$(part USERDATA) || UD=$(part DATA) || abort "USERDATA partition not found"
SYS=$(part SYSTEM) || SYS=""
ui_print "BOOT     : $BOOT"
ui_print "USERDATA : $UD  (will become the Kali root)"
[ "$BOOT" != "$UD" ] || abort "BOOT and USERDATA resolve to the same device"
UD_SZ=$(size_of "$UD")
BOOT_SZ=$(size_of "$BOOT")
[ "$BOOT_SZ" -ge 8388608 ] && [ "$BOOT_SZ" -le 134217728 ] || abort "BOOT partition has an unexpected size, not writing anything"
[ "$UD_SZ" -ge 8589934592 ] || abort "USERDATA is smaller than 8 GB, not the partition I expected. Nothing was written."

# the zip must NOT live on the internal storage, it is erased by this install
ZREAL=$(readlink -f "$ZIPFILE")
ZDEV=$(df -P "$ZREAL" 2>/dev/null | tail -1 | awk '{print $1}')
case "$ZREAL" in
  /data/*|/sdcard/*|/storage/emulated/*|/system/*|/system_root/*)
    abort "this zip is on the internal storage, which this install erases. Copy it to the microSD card and install it from there. Nothing was written." ;;
esac
[ "$(readlink -f "$ZDEV" 2>/dev/null)" != "$UD" ] || abort "this zip is on the internal storage, which this install erases. Copy it to the microSD card and install it from there. Nothing was written."
ZSIZE=$(file_size "$ZIPFILE")
[ -n "$ZSIZE" ] && [ "$ZSIZE" -gt 1048576 ] || abort "cannot read the zip file"

# the SD card also holds the BOOT backup (and a local copy of the zip if it came by sideload)
WORK=""
for d in /external_sd /sdcard1 /usb_otg /external_sdcard; do
  if sd_dir "$d"; then
    FREE=$(free_kb "$d")
    if [ -n "$FREE" ] && [ "$FREE" -gt $(( BOOT_SZ / 1024 * 2 + 65536 )) ] 2>/dev/null; then WORK="$d"; break; fi
  fi
done
[ -n "$WORK" ] || abort "no writable microSD card found (need about 100 MB free on it). Nothing was written."
BK="$WORK/Kali-backup"
mkdir -p "$BK" || abort "cannot create $BK. Nothing was written."

Z="$ZIPFILE"
case "$ZREAL" in
  /sideload/*)
    FREE=$(free_kb "$WORK")
    [ -n "$FREE" ] && [ "$FREE" -gt $(( ZSIZE / 1024 + 131072 )) ] 2>/dev/null || abort "sideload needs the SD card to hold a copy of the zip, and it does not have the space. Copy the zip to the SD card instead."
    ui_print "Sideload detected: copying the zip to the SD card first (a few minutes)..."
    LOCALZ="$BK/.kali-install.zip"
    rm -f "$LOCALZ"
    dd if="$ZIPFILE" of="$LOCALZ" bs=1048576 2>/dev/null
    sync
    [ "$(file_size "$LOCALZ")" = "$ZSIZE" ] || abort "copying the zip from sideload failed. Copy the zip to the SD card instead. Nothing was written."
    Z="$LOCALZ"
    ;;
esac

MF=$(unzip -p "$Z" kali.manifest 2>/dev/null)
[ -n "$MF" ] || abort "zip is incomplete or unreadable (manifest missing). Nothing was written."
BOOT_IMG_SZ=$(mf boot_size)
IMG_SZ=$(mf root_size)
NCH=$(mf chunks)
BOOT_MD5=$(mf md5 boot)
ROOT_MD5=$(mf md5 root)
[ -n "$BOOT_IMG_SZ" ] && [ -n "$IMG_SZ" ] && [ -n "$NCH" ] && [ -n "$BOOT_MD5" ] && [ -n "$ROOT_MD5" ] || abort "zip manifest is damaged. Nothing was written."
ui_print "rootfs image $((IMG_SZ/1048576)) MB -> USERDATA $((UD_SZ/1048576)) MB"
ui_print "boot image   $((BOOT_IMG_SZ/1024)) KB -> BOOT     $((BOOT_SZ/1024)) KB"
[ "$IMG_SZ" -le "$UD_SZ" ] || abort "USERDATA is too small for the Kali image"
[ "$BOOT_IMG_SZ" -le "$BOOT_SZ" ] || abort "boot.img does not fit in the BOOT partition. Nothing was written."

# check every part of the zip against the checksums stored inside it before anything is touched
ui_print "Checking the zip (a few minutes)..."
got=$(unzip -p "$Z" boot.img 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$got" = "$BOOT_MD5" ] || abort "boot.img in the zip is bad (want $BOOT_MD5, got $got). Nothing was written."
i=0
while [ "$i" -lt "$NCH" ]; do
  n=$(printf "c%02d" "$i")
  want=$(mf md5 "$n")
  [ -n "$want" ] || abort "manifest has no checksum for part $n. Nothing was written."
  got=$(unzip -p "$Z" "root/$n.img" 2>/dev/null | md5sum | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    got=$(unzip -p "$Z" "root/$n.img" 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
      bytes=$(unzip -p "$Z" "root/$n.img" 2>/dev/null | wc -c)
      ui_print "part $n: want $want"
      ui_print "part $n: got  $got"
      ui_print "part $n: $bytes bytes read, expected $(mf size "$n")"
      abort "part $n of the root image failed its check. Nothing was written."
    fi
  fi
  i=$((i+1))
  [ $((i % 4)) -eq 0 ] && ui_print "  checked $i of $NCH parts"
done
ui_print "Zip is intact."

# keep the Wi-Fi hotspot settings of the old Kali, if there is one (best effort)
NMTAR=/tmp/kali-nm.tar
rm -f "$NMTAR"
if [ -n "$SYS" ]; then
  umount "$SYS" 2>/dev/null
  mkdir -p /tmp/kali-oldroot
  if mount -t ext4 -o ro "$SYS" /tmp/kali-oldroot 2>/dev/null; then
    ( cd /tmp/kali-oldroot/etc/NetworkManager 2>/dev/null && tar -cf "$NMTAR" system-connections 2>/dev/null )
    umount /tmp/kali-oldroot 2>/dev/null
  fi
fi
[ -s "$NMTAR" ] && ui_print "Saved the old Kali's Wi-Fi settings."

# back up the current boot image (so you can go back to Android)
BOOT_IS_KALI=0
dd if="$BOOT" bs=1048576 2>/dev/null | grep -q pmos_rootfsopts && BOOT_IS_KALI=1
if [ -s "$BK/boot-original.img" ] && ! grep -q pmos_rootfsopts "$BK/boot-original.img"; then
  ui_print "Keeping the existing backup $BK/boot-original.img"
elif [ "$BOOT_IS_KALI" = "1" ]; then
  ui_print "WARNING: BOOT already holds a Kali image and there is no Android boot backup."
  ui_print "To go back to Android later, flash your ROM's boot image."
else
  dd if="$BOOT" of="$BK/boot-original.img" bs=1048576 2>/dev/null || abort "could not back up BOOT. Nothing was written."
  sync
  [ "$(md5_head "$BK/boot-original.img" "$BOOT_SZ")" = "$(md5_head "$BOOT" "$BOOT_SZ")" ] || abort "BOOT backup does not match the partition. Nothing was written."
  ui_print "Backed up old BOOT to $BK/boot-original.img (verified)"
fi

ui_print " "
ui_print "ERASING the internal storage and writing Kali to it (a few minutes)..."
umount /sdcard 2>/dev/null; umount /data/media 2>/dev/null; umount /data 2>/dev/null; umount "$UD" 2>/dev/null
grep -q "^$UD " /proc/mounts && abort "cannot unmount the data partition. Nothing was written."
(
  i=0
  while [ "$i" -lt "$NCH" ]; do
    unzip -p "$Z" "$(printf "root/c%02d.img" "$i")" || exit 1
    i=$((i+1))
  done
) | dd of="$UD" bs=1048576 2>/dev/null || abort "writing the rootfs failed - the internal storage is now broken. Re-flash this zip from the SD card."
sync
ui_print "Verifying root filesystem..."
GOT=$(md5_head "$UD" "$IMG_SZ")
[ "$ROOT_MD5" = "$GOT" ] || abort "rootfs verification failed (want $ROOT_MD5, got $GOT). Re-flash this zip from the SD card."
ui_print "Root filesystem written and verified."

# put the old Wi-Fi settings into the new root (best effort)
if [ -s "$NMTAR" ]; then
  mkdir -p /tmp/kali-newroot
  if mount -t ext4 -o rw "$UD" /tmp/kali-newroot 2>/dev/null; then
    mkdir -p /tmp/kali-newroot/etc/NetworkManager
    ( cd /tmp/kali-newroot/etc/NetworkManager && tar -xf "$NMTAR" 2>/dev/null && chmod 600 system-connections/* 2>/dev/null )
    sync
    umount /tmp/kali-newroot 2>/dev/null
    ui_print "Wi-Fi settings copied to the new Kali."
  else
    ui_print "Could not copy the Wi-Fi settings (join Wi-Fi from the desktop instead)."
  fi
fi

# The filesystem is NOT resized here: TWRP's e2fsprogs is too old. Kali grows it to the whole partition on first boot.

ui_print "Writing boot image to BOOT..."
unzip -p "$Z" boot.img | dd of="$BOOT" bs=1048576 2>/dev/null || {
  ui_print "Writing BOOT failed - restoring the old boot image..."
  [ -s "$BK/boot-original.img" ] && dd if="$BK/boot-original.img" of="$BOOT" bs=1048576 2>/dev/null
  abort "writing BOOT failed. Old boot image: $BK/boot-original.img"
}
sync
GOT=$(md5_head "$BOOT" "$BOOT_IMG_SZ")
if [ "$BOOT_MD5" != "$GOT" ]; then
  ui_print "BOOT verification failed - restoring the old boot image..."
  [ -s "$BK/boot-original.img" ] && dd if="$BK/boot-original.img" of="$BOOT" bs=1048576 2>/dev/null
  sync
  abort "BOOT verification failed. Old boot image: $BK/boot-original.img"
fi
ui_print "Boot image verified."

cleanup
ui_print " "
ui_print "Done. Reboot to system."
ui_print "First boot takes 2-4 minutes (it grows the filesystem"
ui_print "to the whole storage and makes new SSH keys), then the"
ui_print "touch desktop appears. The panel is at the top, the"
ui_print "on-screen keyboard docks at the bottom."
ui_print "Join Wi-Fi with the network icon in the panel."
ui_print "Login: kali / kali  (change the password!)"
exit 0
