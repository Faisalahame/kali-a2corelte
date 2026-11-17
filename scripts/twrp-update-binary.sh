#!/sbin/sh
# Kali Linux for the Samsung Galaxy A2 Core (SM-A260G / a2corelte) - TWRP installer.
# Template: scripts/mkzip.py fills in the @PLACEHOLDERS@ and stores this file as
# META-INF/com/google/android/update-binary.
#
# The two images (kali/boot.img and kali/disk.img) are stored UNCOMPRESSED and aligned
# to 32 KiB inside the zip, so they are copied straight out of the zip with plain dd.
# No unzip / busybox / edify interpreter is needed on the phone.

OUTFD="$2"
ZIP="$3"

BS=32768
BOOT_SKIP=@BOOT_SKIP@
BOOT_BLOCKS=@BOOT_BLOCKS@
BOOT_KB=@BOOT_KB@
BOOT_MD5=@BOOT_MD5@
DISK_SKIP=@DISK_SKIP@
DISK_BLOCKS=@DISK_BLOCKS@
DISK_KB=@DISK_KB@
DISK_MD5=@DISK_MD5@

# Test hook: point this at a directory of files to try the installer without a phone.
BY="${KALI_BY_NAME:-/dev/block/platform/13540000.dwmmc0/by-name}"

ui_print() {
  echo "ui_print $1" >> /proc/self/fd/$OUTFD
  echo "ui_print" >> /proc/self/fd/$OUTFD
}

abort() {
  ui_print " "
  ui_print "ERROR: $1"
  [ -n "$2" ] && ui_print "$2"
  exit 1
}

# All sizes are handled in KiB: the shell on some recoveries has 32-bit arithmetic and a
# 13 GB data partition would overflow it when counted in bytes.
mb() { echo $(( $1 / 1024 )); }

find_part() {
  if [ -e "$BY/$1" ]; then echo "$BY/$1"; return; fi
  for d in /dev/block/platform/*/by-name/$1 /dev/block/by-name/$1; do
    if [ -e "$d" ]; then echo "$d"; return; fi
  done
}

part_kb() {
  if [ -f "$1" ]; then
    set -- $(wc -c < "$1")
    echo $(( $1 / 1024 ))
    return
  fi
  b=$(blockdev --getsz "$1" 2>/dev/null)
  if [ -n "$b" ]; then echo $(( b / 2 )); return; fi
  real=$(readlink -f "$1" 2>/dev/null)
  [ -n "$real" ] || real="$1"
  s=$(cat "/sys/class/block/${real##*/}/size" 2>/dev/null)
  if [ -n "$s" ]; then echo $(( s / 2 )); fi
}

# md5 of the first $2 blocks of $1
md5_blocks() {
  set -- $(dd if="$1" bs=$BS count="$2" 2>/dev/null | md5sum)
  echo "$1"
}

ui_print " "
ui_print "=============================================="
ui_print "  Kali Linux for Samsung Galaxy A2 Core"
ui_print "=============================================="

# ---------- 1. is this the right phone? ----------
INFO=""
for p in ro.product.device ro.build.product ro.product.name ro.product.model ro.bootloader; do
  INFO="$INFO $(getprop $p)"
done
case "$INFO" in
  *a2core*|*A2CORE*|*A260*) ;;
  *)
    if [ ! -e /sdcard/kali-skip-device-check ]; then
      abort "This zip is only for the Galaxy A2 Core (SM-A260G)." "TWRP reports:$INFO"
    fi
    ui_print "Device check skipped (kali-skip-device-check found)"
    ;;
esac

# ---------- 2. find the partitions ----------
BOOT=$(find_part BOOT)
SYSTEM=$(find_part SYSTEM)
DATA=$(find_part USERDATA)
[ -n "$BOOT" ] || abort "BOOT partition not found." "Nothing was changed."

# Where does Kali go?
#  - zip on the phone's storage (/sdcard) -> SYSTEM. /data holds this zip, so it must stay untouched.
#  - zip on an SD card or USB-OTG stick   -> USERDATA (all the free space, but erases all phone data).
case "$ZIP" in
  /external_sd/*|/usb-otg/*|/usb_otg/*|/sdcard1/*|/storage/sdcard1/*|/mnt/media_rw/*|/otg/*)
    MODE=data; TARGET="$DATA"; TNAME=USERDATA ;;
  *)
    MODE=system; TARGET="$SYSTEM"; TNAME=SYSTEM ;;
esac
[ -n "$TARGET" ] || abort "$TNAME partition not found." "Nothing was changed."

# ---------- 3. size checks (before anything is written) ----------
BSZ=$(part_kb "$BOOT")
TSZ=$(part_kb "$TARGET")
[ -n "$BSZ" ] || abort "Cannot read the size of the BOOT partition." "Nothing was changed."
[ -n "$TSZ" ] || abort "Cannot read the size of the $TNAME partition." "Nothing was changed."
ui_print "BOOT partition:   $(mb $BSZ) MB   (boot.img needs $(mb $BOOT_KB) MB)"
ui_print "$TNAME partition: $(mb $TSZ) MB   (Kali needs $(mb $DISK_KB) MB)"
if [ "$BSZ" -lt "$BOOT_KB" ]; then
  abort "boot.img does not fit into the BOOT partition." "Nothing was changed. Send this log to get a smaller kernel."
fi
if [ "$TSZ" -lt "$DISK_KB" ]; then
  abort "The Kali image does not fit into the $TNAME partition." "Nothing was changed."
fi
[ -f "$ZIP" ] || abort "Cannot read the zip file ($ZIP)." "Nothing was changed."

ui_print " "
ui_print "Kali will be installed to: $TNAME"
if [ "$MODE" = system ]; then
  ui_print "This ERASES the Android system and replaces the boot image."
  ui_print "Your files in /sdcard are kept."
else
  ui_print "This ERASES ALL DATA (Android, apps, /sdcard) and the boot image."
fi

# ---------- 4. back up the current boot image ----------
BK="${ZIP%/*}/Android-boot-backup-$(date +%Y%m%d-%H%M%S).img"
if dd if="$BOOT" of="$BK" bs=1048576 2>/dev/null; then
  ui_print "Current boot image saved to: $BK"
else
  rm -f "$BK"
  ui_print "WARNING: could not save the current boot image."
fi

# ---------- 5. unmount the target ----------
if [ "$MODE" = system ]; then
  for m in /system /system_root /mnt/system; do umount "$m" 2>/dev/null; done
else
  for m in /sdcard /storage/emulated /data/media /data; do umount "$m" 2>/dev/null; done
fi
REAL=$(readlink -f "$TARGET" 2>/dev/null)
if [ -f /proc/mounts ] && grep -q -e "^$TARGET " -e "^$REAL " /proc/mounts; then
  abort "$TNAME is still mounted and cannot be unmounted." "Nothing was changed."
fi

# ---------- 6. write Kali ----------
ui_print " "
ui_print "Writing Kali to $TNAME ($(mb $DISK_KB) MB) - this takes a few minutes, do not turn the phone off..."
dd if="$ZIP" of="$TARGET" bs=$BS skip=$DISK_SKIP count=$DISK_BLOCKS conv=notrunc 2>/dev/null
sync
ui_print "Verifying..."
if [ "$(md5_blocks "$TARGET" $DISK_BLOCKS)" != "$DISK_MD5" ]; then
  abort "Verification of the $TNAME write failed." "Do NOT reboot. Run the zip again."
fi

ui_print "Writing boot image..."
dd if="$ZIP" of="$BOOT" bs=$BS skip=$BOOT_SKIP count=$BOOT_BLOCKS conv=notrunc 2>/dev/null
sync
if [ "$(md5_blocks "$BOOT" $BOOT_BLOCKS)" != "$BOOT_MD5" ]; then
  abort "Verification of the boot image failed." "Do NOT reboot. Run the zip again."
fi

ui_print " "
ui_print "Done. Reboot to system."
ui_print "First boot: the root filesystem grows to fill the partition (1-2 minutes)."
ui_print "Login: kali / kali   (root / kali)"
ui_print "USB networking: plug into a PC, then ssh kali@172.16.42.1"
ui_print "To go back to Android: flash your Android boot image and system again."
ui_print " "
exit 0
