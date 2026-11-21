#!/sbin/sh
# Kali Linux for Samsung Galaxy A2 Core - all-in-one TWRP installer (aio-4)
# Writes the Kali root filesystem (touch desktop included) to the INTERNAL STORAGE (USERDATA) and boot.img to BOOT.
# Send it with "adb sideload kali-a2corelte-aio.zip" (TWRP: Advanced -> ADB Sideload). SYSTEM is not touched.
# Nothing is written until every check on the zip has passed. There is no backup step.
# aio-4: the recovery shell does 32-bit math, so sizes over 2 GB wrapped around (the root image showed as -1975 MB, the
#        internal storage as 828 MB, and the read-back check got empty data). All size math is now done with awk.
OUTFD=/proc/self/fd/$2
ZIPFILE="$3"

ui_print() { echo "ui_print $1" > "$OUTFD"; echo "ui_print" > "$OUTFD"; }
abort() { ui_print " "; ui_print "ERROR: $1"; ui_print "Aborting."; exit 1; }

# ---- number helpers: awk uses 64-bit floating point, the shell here only has 32-bit integers ----
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}'; }
mb() { awk -v a="$1" 'BEGIN{printf "%.0f", a/1048576}'; }
kb() { awk -v a="$1" 'BEGIN{printf "%.0f", a/1024}'; }

part() {
  for n in "$1" "$(echo "$1" | tr 'A-Z' 'a-z')"; do
    for d in /dev/block/platform/*/by-name /dev/block/by-name; do
      if [ -e "$d/$n" ]; then readlink -f "$d/$n"; return 0; fi
    done
  done
  return 1
}
# size of a block device in bytes (sectors * 512, computed by awk)
size_of() { b=$(basename "$1"); awk -v s="$(cat "/sys/class/block/$b/size" 2>/dev/null)" 'BEGIN{printf "%.0f", s*512}'; }
file_size() { ls -l "$1" 2>/dev/null | awk '{print $5}'; }
# md5 of exactly the first $2 bytes of $1, using only dd + md5sum.
# The block size is the biggest one that divides the byte count, so no partial block is needed.
md5_exact() {
  mx_dev="$1"; mx_sz="$2"
  for mx_bs in 1048576 32768 4096 512 16 1; do
    mx_cnt=$(awk -v s="$mx_sz" -v b="$mx_bs" 'BEGIN{ if (s % b == 0) printf "%.0f", s/b }')
    [ -n "$mx_cnt" ] && break
  done
  dd if="$mx_dev" bs=$mx_bs count=$mx_cnt 2>/dev/null | md5sum | cut -d' ' -f1
}
mf() {
  if [ -n "$2" ]; then echo "$MF" | awk -v k="$1" -v n="$2" '$1==k && $2==n {print $3; exit}'
  else echo "$MF" | awk -v k="$1" '$1==k {print $2; exit}'; fi
}

ui_print "======================================================"
ui_print "  Kali Linux - Galaxy A2 Core - installs to internal storage"
ui_print "  installer aio-4"
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
ge "$BOOT_SZ" 8388608 && le "$BOOT_SZ" 134217728 || abort "BOOT partition has an unexpected size ($BOOT_SZ bytes), not writing anything"
ge "$UD_SZ" 4294967296 || abort "internal storage partition is smaller than 4 GB ($UD_SZ bytes), not writing anything"

# the zip must come through adb sideload: if it were on the internal storage it would be erased by this install
ZREAL=$(readlink -f "$ZIPFILE")
[ -n "$ZREAL" ] || ZREAL="$ZIPFILE"
case "$ZREAL" in
  /data/*|/sdcard/*|/system/*|/system_root/*) abort "this zip is on the phone's internal storage, which this install erases. Use adb sideload." ;;
esac
ZDEV=$(df -P "$ZREAL" 2>/dev/null | tail -1 | awk '{print $1}')
[ "$ZDEV" != "$UD" ] || abort "this zip is on the internal storage, which this install erases. Use adb sideload."
ZSIZE=$(file_size "$ZIPFILE")
[ -n "$ZSIZE" ] && ge "$ZSIZE" 1048576 || abort "cannot read the zip file"

MF=$(unzip -p "$ZIPFILE" kali.manifest 2>/dev/null)
[ -n "$MF" ] || abort "zip is incomplete or unreadable (manifest missing). Nothing was written."
BOOT_IMG_SZ=$(mf boot_size); IMG_SZ=$(mf root_size); NCH=$(mf chunks)
BOOT_MD5=$(mf md5 boot); ROOT_MD5=$(mf md5 root)
[ -n "$BOOT_IMG_SZ" ] && [ -n "$IMG_SZ" ] && [ -n "$NCH" ] && [ -n "$BOOT_MD5" ] && [ -n "$ROOT_MD5" ] || abort "zip manifest is damaged. Nothing was written."
ui_print "rootfs image $(mb "$IMG_SZ") MB -> internal storage $(mb "$UD_SZ") MB (grown to full size on first boot)"
ui_print "boot image   $(kb "$BOOT_IMG_SZ") KB -> BOOT $(kb "$BOOT_SZ") KB"
le "$IMG_SZ" "$UD_SZ" || abort "internal storage is too small for the Kali image"
le "$BOOT_IMG_SZ" "$BOOT_SZ" || abort "boot.img does not fit in the BOOT partition. Nothing was written."

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

ui_print "Writing boot image to BOOT..."
unzip -p "$ZIPFILE" boot.img | dd of="$BOOT" bs=1048576 2>/dev/null || abort "writing BOOT failed - re-flash this zip"
sync
GOT=$(md5_exact "$BOOT" "$BOOT_IMG_SZ")
[ "$BOOT_MD5" = "$GOT" ] || abort "BOOT verification failed - re-flash this zip"
ui_print "Boot image verified."

ui_print " "
ui_print "Done. Reboot to system (TWRP may say 'Failed to mount /data': normal)."
ui_print "First boot takes a few minutes (it grows the filesystem to the whole"
ui_print "internal storage, then the touch desktop appears)."
ui_print "Login: kali / kali (change it with passwd). SSH over USB 172.16.42.1."
ui_print "Do NOT use TWRP Wipe/Format Data afterwards: Kali lives there now."
exit 0
