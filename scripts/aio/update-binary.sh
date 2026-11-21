#!/sbin/sh
# Kali Linux for Samsung Galaxy A2 Core - all-in-one TWRP installer (aio-2)
# Writes the Kali root filesystem (touch desktop included) to the INTERNAL STORAGE (USERDATA) and boot.img to BOOT.
# The zip must be on the microSD card, because USERDATA is erased. SYSTEM is not touched.
# Nothing is written until every check has passed and the old BOOT is backed up.
# aio-2: read-back checks no longer use "head -c" (it returned nothing in TWRP, so the md5 was that of empty data).
OUTFD=/proc/self/fd/$2
ZIPFILE="$3"

ui_print() { echo "ui_print $1" > "$OUTFD"; echo "ui_print" > "$OUTFD"; }
abort() { ui_print " "; ui_print "ERROR: $1"; ui_print "Aborting."; exit 1; }

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
free_kb() { df -P "$1" 2>/dev/null | tail -1 | awk '{print $4}'; }
# md5 of exactly the first $2 bytes of $1, using only dd + md5sum (like the older installer that verified fine here).
# The block size is the biggest one that divides the byte count, so no partial block is needed.
md5_exact() {
  mx_dev="$1"; mx_sz="$2"
  for mx_bs in 1048576 32768 4096 512 16 1; do
    [ $((mx_sz % mx_bs)) -eq 0 ] && break
  done
  dd if="$mx_dev" bs=$mx_bs count=$((mx_sz / mx_bs)) 2>/dev/null | md5sum | cut -d' ' -f1
}
mf() {
  if [ -n "$2" ]; then echo "$MF" | awk -v k="$1" -v n="$2" '$1==k && $2==n {print $3; exit}'
  else echo "$MF" | awk -v k="$1" '$1==k {print $2; exit}'; fi
}

ui_print "======================================================"
ui_print "  Kali Linux - Galaxy A2 Core - installs to internal storage"
ui_print "  installer aio-2"
ui_print "======================================================"
DEV=$(getprop ro.product.device)
[ -n "$DEV" ] || DEV=$(getprop ro.build.product)
ui_print "Device: $DEV"
case "$DEV" in a2core*) ;; *) abort "this zip is only for the Galaxy A2 Core (a2corelte), found '$DEV'" ;; esac

BOOT=$(part BOOT) || abort "BOOT partition not found"
UD=$(part USERDATA) || UD=$(part DATA) || abort "USERDATA (internal storage) partition not found"
ui_print "BOOT     : $BOOT"
ui_print "INTERNAL : $UD"
[ "$BOOT" != "$UD" ] || abort "BOOT and USERDATA resolve to the same device"
UD_SZ=$(size_of "$UD")
BOOT_SZ=$(size_of "$BOOT")
[ "$BOOT_SZ" -ge 8388608 ] && [ "$BOOT_SZ" -le 134217728 ] || abort "BOOT partition has an unexpected size, not writing anything"
[ "$UD_SZ" -ge 4294967296 ] || abort "internal storage partition is smaller than 4 GB, not writing anything"

# the zip must NOT be on the internal storage (it is erased by this install)
ZREAL=$(readlink -f "$ZIPFILE")
ZDEV=$(df -P "$ZREAL" 2>/dev/null | tail -1 | awk '{print $1}')
case "$ZREAL" in
  /data/*|/sdcard/*|/system/*|/system_root/*|/sideload/*|/tmp/*)
    abort "this zip is on the phone's internal storage (or sideload), which this install erases. Copy it to the microSD card and install it from there." ;;
esac
[ "$ZDEV" != "$UD" ] || abort "this zip is on the internal storage, which this install erases. Copy it to the microSD card."
case "$ZDEV" in /dev/block/mmcblk0*) abort "this zip is on the phone's internal memory. Copy it to the microSD card." ;; esac
ZSIZE=$(file_size "$ZIPFILE")
[ -n "$ZSIZE" ] && [ "$ZSIZE" -gt 1048576 ] || abort "cannot read the zip file"
ZDIR=$(dirname "$ZREAL")
[ -d "$ZDIR" ] && [ -w "$ZDIR" ] || abort "the folder of the zip is not writable ($ZDIR)"
FREE=$(free_kb "$ZDIR")
[ -n "$FREE" ] && [ "$FREE" -gt 70000 ] 2>/dev/null || abort "less than 70 MB free next to the zip on the SD card (needed for the BOOT backup)"
BK="$ZDIR/Kali-backup"
mkdir -p "$BK" || abort "cannot create $BK. Nothing was written."

MF=$(unzip -p "$ZIPFILE" kali.manifest 2>/dev/null)
[ -n "$MF" ] || abort "zip is incomplete or unreadable (manifest missing). Nothing was written."
BOOT_IMG_SZ=$(mf boot_size); IMG_SZ=$(mf root_size); NCH=$(mf chunks)
BOOT_MD5=$(mf md5 boot); ROOT_MD5=$(mf md5 root)
[ -n "$BOOT_IMG_SZ" ] && [ -n "$IMG_SZ" ] && [ -n "$NCH" ] && [ -n "$BOOT_MD5" ] && [ -n "$ROOT_MD5" ] || abort "zip manifest is damaged. Nothing was written."
ui_print "rootfs image $((IMG_SZ/1048576)) MB -> internal storage $((UD_SZ/1048576)) MB (grown to full size on first boot)"
ui_print "boot image   $((BOOT_IMG_SZ/1024)) KB -> BOOT $((BOOT_SZ/1024)) KB"
[ "$IMG_SZ" -le "$UD_SZ" ] || abort "internal storage is too small for the Kali image"
[ "$BOOT_IMG_SZ" -le "$BOOT_SZ" ] || abort "boot.img does not fit in the BOOT partition. Nothing was written."

# the read-back check must work BEFORE anything is erased: test it on the BOOT partition, whose md5 we can compare with itself
ui_print "Testing the read-back check on BOOT..."
T1=$(md5_exact "$BOOT" "$BOOT_SZ"); T2=$(md5_exact "$BOOT" "$BOOT_SZ")
[ "$T1" = "$T2" ] && [ "$T1" != "d41d8cd98f00b204e9800998ecf8427e" ] || abort "cannot read the BOOT partition back (md5 $T1 / $T2). Nothing was written."

ui_print "Checking the zip (a few minutes)..."
got=$(unzip -p "$ZIPFILE" boot.img 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$got" = "$BOOT_MD5" ] || abort "boot.img in the zip is bad (want $BOOT_MD5, got $got). Nothing was written."
i=0
while [ "$i" -lt "$NCH" ]; do
  n=$(printf "c%02d" "$i")
  want=$(mf md5 "$n")
  [ -n "$want" ] || abort "manifest has no checksum for part $n. Nothing was written."
  got=$(unzip -p "$ZIPFILE" "root/$n.img" 2>/dev/null | md5sum | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    got=$(unzip -p "$ZIPFILE" "root/$n.img" 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
      bytes=$(unzip -p "$ZIPFILE" "root/$n.img" 2>/dev/null | wc -c)
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

# optional Wi-Fi: a text file kali-wifi.txt next to the zip (line 1 = network name, line 2 = password)
WIFI_SSID=""; WIFI_PSK=""
if [ -f "$ZDIR/kali-wifi.txt" ]; then
  WIFI_SSID=$(sed -n 1p "$ZDIR/kali-wifi.txt" | tr -d '\r')
  WIFI_PSK=$(sed -n 2p "$ZDIR/kali-wifi.txt" | tr -d '\r')
  [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ] && ui_print "Found kali-wifi.txt: will set up Wi-Fi '$WIFI_SSID'"
fi

# back up the current boot image
BOOT_IS_KALI=0
dd if="$BOOT" bs=1048576 2>/dev/null | grep -q pmos_rootfsopts && BOOT_IS_KALI=1
if [ -s "$BK/boot-original.img" ] && ! grep -q pmos_rootfsopts "$BK/boot-original.img"; then
  ui_print "Keeping the existing backup $BK/boot-original.img"
elif [ "$BOOT_IS_KALI" = "1" ]; then
  ui_print "NOTE: BOOT already holds a Kali image, so there is no Android boot backup."
else
  dd if="$BOOT" of="$BK/boot-original.img" bs=1048576 2>/dev/null || abort "could not back up BOOT. Nothing was written."
  sync
  [ "$(md5_exact "$BK/boot-original.img" "$BOOT_SZ")" = "$(md5_exact "$BOOT" "$BOOT_SZ")" ] || abort "BOOT backup does not match the partition. Nothing was written."
  ui_print "Backed up old BOOT to $BK/boot-original.img (verified)"
fi

ui_print " "
ui_print "ERASING the internal storage (Android data and photos) and writing Kali..."
# release the internal storage
umount /sdcard 2>/dev/null; umount /data/media 2>/dev/null; umount /data 2>/dev/null; umount "$UD" 2>/dev/null
grep -q "^$UD " /proc/mounts && abort "cannot unmount the internal storage ($UD). Nothing was written."
rm -f /tmp/unz-failed /tmp/dd-write.log
(
  i=0
  while [ "$i" -lt "$NCH" ]; do
    unzip -p "$ZIPFILE" "$(printf "root/c%02d.img" "$i")" || { touch /tmp/unz-failed; exit 1; }
    i=$((i+1))
  done
) | dd of="$UD" bs=1048576 2>/tmp/dd-write.log
DDRC=$?
sync
if [ -e /tmp/unz-failed ] || [ "$DDRC" -ne 0 ]; then
  ui_print "dd exit code $DDRC; $(tail -n 2 /tmp/dd-write.log 2>/dev/null | tr '\n' ' ')"
  abort "writing the rootfs failed - the internal storage is now broken, re-flash this zip"
fi
ui_print "Verifying..."
GOT=$(md5_exact "$UD" "$IMG_SZ")
if [ "$ROOT_MD5" != "$GOT" ]; then
  # help find out what went wrong: compare the first MB on the phone with the first MB of the zip
  ui_print "read-back bytes (first 1 MB test): $(dd if="$UD" bs=32768 count=32 2>/dev/null | wc -c)"
  ui_print "phone first MB md5: $(dd if="$UD" bs=32768 count=32 2>/dev/null | md5sum | cut -d' ' -f1)"
  ui_print "zip   first MB md5: $(unzip -p "$ZIPFILE" root/c00.img 2>/dev/null | dd bs=32768 count=32 2>/dev/null | md5sum | cut -d' ' -f1)"
  abort "rootfs verification failed (want $ROOT_MD5, got $GOT) - re-flash this zip"
fi
ui_print "Root filesystem written and verified."

# optional Wi-Fi setup inside the new root
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ]; then
  mkdir -p /tmp/kroot
  if mount -t ext4 -o rw "$UD" /tmp/kroot 2>/dev/null; then
    D=/tmp/kroot/etc/NetworkManager/system-connections
    mkdir -p "$D"
    {
      echo "[connection]"; echo "id=hotspot"; echo "type=wifi"; echo "autoconnect=true"
      echo "[wifi]"; echo "mode=infrastructure"; echo "ssid=$WIFI_SSID"
      echo "[wifi-security]"; echo "key-mgmt=wpa-psk"; echo "psk=$WIFI_PSK"
      echo "[ipv4]"; echo "method=auto"; echo "[ipv6]"; echo "method=auto"
    } > "$D/hotspot.nmconnection"
    chmod 600 "$D/hotspot.nmconnection"
    sync; umount /tmp/kroot
    ui_print "Wi-Fi '$WIFI_SSID' saved."
  else
    ui_print "Could not mount the new root to save Wi-Fi (not fatal): choose Wi-Fi on the phone screen instead."
  fi
fi

ui_print "Writing boot image to BOOT..."
unzip -p "$ZIPFILE" boot.img | dd of="$BOOT" bs=1048576 2>/dev/null || {
  ui_print "Writing BOOT failed - restoring the old boot image..."
  [ -s "$BK/boot-original.img" ] && dd if="$BK/boot-original.img" of="$BOOT" bs=1048576 2>/dev/null
  abort "writing BOOT failed. Old boot image: $BK/boot-original.img"
}
sync
GOT=$(md5_exact "$BOOT" "$BOOT_IMG_SZ")
if [ "$BOOT_MD5" != "$GOT" ]; then
  ui_print "BOOT verification failed - restoring the old boot image..."
  [ -s "$BK/boot-original.img" ] && dd if="$BK/boot-original.img" of="$BOOT" bs=1048576 2>/dev/null
  sync
  abort "BOOT verification failed. Old boot image: $BK/boot-original.img"
fi
ui_print "Boot image verified."

ui_print " "
ui_print "Done. Reboot to system (TWRP may say 'Failed to mount /data': normal)."
ui_print "First boot takes a few minutes (it grows the filesystem to the whole"
ui_print "internal storage, then the touch desktop appears)."
ui_print "Login: kali / kali (change it with passwd). SSH over Wi-Fi or USB 172.16.42.1."
ui_print "Do NOT use TWRP Wipe/Format Data afterwards: Kali lives there now."
exit 0
