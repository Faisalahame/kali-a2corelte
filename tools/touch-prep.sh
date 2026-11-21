#!/sbin/sh
# Run in TWRP (adb shell sh /tmp/touch-prep.sh). Prepares the installed Kali for touch debugging WITHOUT a rebuild:
#  1. makes the touchscreen + i2c bus drivers load at every boot (/etc/modules-load.d/touch.conf)
#  2. adds a one-shot service that, 45 s after boot, writes everything about the touch chip to /var/log/touch-debug.txt
# Nothing else on the phone is changed. Read the result later from TWRP: /k/var/log/touch-debug.txt
umount /sdcard 2>/dev/null; umount /data/media 2>/dev/null; umount /data 2>/dev/null; umount /k 2>/dev/null
mkdir -p /k
mount -t ext4 -o rw /dev/block/mmcblk0p26 /k || { echo "mount failed"; grep mmcblk0p26 /proc/mounts; exit 1; }
[ -d /k/etc/systemd/system ] || { echo "this is not the Kali root (no /etc/systemd/system)"; umount /k; exit 1; }

mkdir -p /k/etc/modules-load.d /k/usr/local/sbin
printf 'i2c-exynos5\nzinitix\nimagis\nmelfas_mip4\n' > /k/etc/modules-load.d/touch.conf

cat > /k/usr/local/sbin/touch-debug.sh <<'EOF'
#!/bin/sh
sleep 45
mount -t debugfs none /sys/kernel/debug 2>/dev/null
{
echo "== date"; date
echo "== uname"; uname -a
echo "== lsmod"; lsmod
echo "== input devices"; cat /proc/bus/input/devices
echo "== i2c devices"; ls -la /sys/bus/i2c/devices/
echo "== i2c drivers"; ls /sys/bus/i2c/drivers/
echo "== deferred probes"; cat /sys/kernel/debug/devices_deferred
echo "== device tree touch nodes"; find /sys/firmware/devicetree/base -iname '*touch*' -o -iname '*zinitix*' -o -iname '*imagis*' -o -iname '*melfas*'
echo "== touch compatible"; for d in $(find /sys/firmware/devicetree/base -iname '*touch*' 2>/dev/null); do echo "$d"; cat "$d/compatible" "$d/status" 2>/dev/null; echo; done
echo "== dmesg"; dmesg | grep -iE 'zinitix|touch|i2c|deferred|defer|probe|regulator|s2m|pmic|input' | tail -150
echo "== modules-load / udev"; journalctl -b --no-pager -u systemd-modules-load -u systemd-udevd 2>&1 | tail -40
echo "== manual modprobe"; modprobe -v i2c-exynos5 2>&1; modprobe -v zinitix 2>&1
sleep 3
echo "== input devices after modprobe"; cat /proc/bus/input/devices
} > /var/log/touch-debug.txt 2>&1
EOF
chmod 755 /k/usr/local/sbin/touch-debug.sh

cat > /k/etc/systemd/system/touch-debug.service <<'EOF'
[Unit]
Description=Write touch debug info
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/touch-debug.sh
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/touch-debug.service /k/etc/systemd/system/multi-user.target.wants/touch-debug.service
sync
umount /k
echo "done - now reboot to system, wait 2 minutes, come back to TWRP"
