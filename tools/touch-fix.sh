#!/sbin/sh
# Run in TWRP:  adb push touch-fix.sh /tmp/ && adb shell sh /tmp/touch-fix.sh ['WIFI-NAME' 'WIFI-PASSWORD']
# No rebuild needed. It changes the installed Kali root like this:
#  1. loads the Synaptics touch driver (rmi_i2c) at boot
#  2. adds a service that, 20 s after boot, re-binds the touch chip's driver (up to 6 tries, with a module reload from
#     the 4th) until a touchscreen shows up. Everything it sees goes to /var/log/touch-rebind.txt (+ /var/log/dmesg-full2.txt)
#  3. OPTIONAL: if you give a Wi-Fi name and password (2.4 GHz), Kali joins that Wi-Fi at boot so you can ssh in
#     (ssh kali@<phone ip>, password kali) even while touch is dead.
# Why: dmesg showed "RMI initial reset failed" and then "cannot create duplicate filename rmi4-00.fn34" (probe error -17)
# on i2c 3-004b. The chip probably was not ready when the driver first talked to it, so we try again later.
SSID="$1"; PSK="$2"
mkdir -p /tmp
export TMPDIR=/tmp
umount /sdcard 2>/dev/null; umount /data/media 2>/dev/null; umount /data 2>/dev/null; umount /k 2>/dev/null
mkdir -p /k
mount -t ext4 -o rw /dev/block/mmcblk0p26 /k || { echo "mount failed"; grep mmcblk0p26 /proc/mounts; exit 1; }
[ -d /k/etc/systemd/system ] || { echo "this is not the Kali root (no /etc/systemd/system)"; umount /k; exit 1; }

mkdir -p /k/etc/modules-load.d /k/usr/local/sbin
printf 'rmi_i2c\n' > /k/etc/modules-load.d/touch.conf

cat > /k/usr/local/sbin/touch-rebind.sh <<'EOF'
#!/bin/sh
LOG=/var/log/touch-rebind.txt
exec > "$LOG" 2>&1
sleep 20
D=/sys/bus/i2c/drivers/rmi4_i2c
has_touch() { grep -q '^B: ABS=' /proc/bus/input/devices; }
echo "== start $(date)"; uname -r
n=0
while [ "$n" -lt 6 ]; do
  if has_touch; then echo "== touchscreen present (after $n re-binds)"; break; fi
  echo "== attempt $n: no touchscreen yet"
  if [ "$n" -ge 3 ]; then
    echo "-- reloading modules"
    modprobe -r rmi_i2c rmi_core 2>&1
    sleep 2
    modprobe rmi_i2c 2>&1
  else
    echo "-- re-binding 3-004b"
    echo 3-004b > "$D/unbind" 2>&1
    sleep 2
    echo 3-004b > "$D/bind" 2>&1
  fi
  sleep 6
  dmesg | grep -iE 'rmi|3-004b|i2c-3' | tail -12
  n=$((n+1))
done
echo "== final input devices"; cat /proc/bus/input/devices
echo "== rmi4 devices"; ls -la /sys/bus/rmi4/devices/ 2>&1
echo "== dmesg rmi/i2c"; dmesg | grep -iE 'rmi|3-004b|i2c-3' | tail -60
echo "== network"; ip -br addr 2>&1; nmcli -t -f NAME,DEVICE,STATE con show 2>&1
dmesg > /var/log/dmesg-full2.txt 2>&1
EOF
chmod 755 /k/usr/local/sbin/touch-rebind.sh

cat > /k/etc/systemd/system/touch-rebind.service <<'EOF'
[Unit]
Description=Retry the touchscreen driver
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/touch-rebind.sh
[Install]
WantedBy=multi-user.target
EOF
chmod 644 /k/etc/systemd/system/touch-rebind.service
rm -f /k/etc/systemd/system/multi-user.target.wants/touch-debug.service
ln -sf /etc/systemd/system/touch-rebind.service /k/etc/systemd/system/multi-user.target.wants/touch-rebind.service

if [ -n "$SSID" ] && [ -n "$PSK" ]; then
  mkdir -p /k/etc/NetworkManager/system-connections
  cat > /k/etc/NetworkManager/system-connections/hotspot.nmconnection <<EOF
[connection]
id=hotspot
uuid=6f1b6c1e-6a3e-4a52-9d1b-3a1f0e5b7c11
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
method=ignore
EOF
  chmod 600 /k/etc/NetworkManager/system-connections/hotspot.nmconnection
  chown 0:0 /k/etc/NetworkManager/system-connections/hotspot.nmconnection 2>/dev/null
  echo "Wi-Fi '$SSID' saved"
fi

for f in /k/etc/modules-load.d/touch.conf /k/usr/local/sbin/touch-rebind.sh /k/etc/systemd/system/touch-rebind.service; do
  [ -s "$f" ] || { echo "ERROR: $f was not written"; sync; umount /k; exit 1; }
done
[ -L /k/etc/systemd/system/multi-user.target.wants/touch-rebind.service ] || { echo "ERROR: service link missing"; sync; umount /k; exit 1; }
sync
umount /k
echo "done, all files written - now reboot to system and wait 2 minutes"
