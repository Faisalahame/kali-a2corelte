#!/usr/bin/env bash
# Builds the Kali arm64 root filesystem WITH the touch desktop already installed, merges in the kernel modules
# and firmware from the postmarketOS image (build-pmos.sh), and writes it as an ext4 image (work/kali-root.img).
# Must run as root.
set -euxo pipefail
cd "$(dirname "$0")/../.."
mkdir -p work out
exec > >(tee -a work/kali.log) 2>&1
TOOLS="${TOOLS:-kali-linux-core}"
ROOT="$PWD/work/kali-root"

cleanup() {
  for p in /proc/[0-9]*; do
    r=$(readlink "$p/root" 2>/dev/null || true)
    case "$r" in "$ROOT"|"$ROOT"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
  done
  sleep 1
  for m in dev sys proc; do umount -R -l "$ROOT/$m" 2>/dev/null || true; done
  umount work/pmos-mnt 2>/dev/null || true
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

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
echo "LABEL=kali_root / ext4 defaults,noatime 0 1" > /etc/fstab
echo "LANG=C.UTF-8" > /etc/default/locale

# the keyring downloaded on the host lacks Kali's newest signing key
apt-get update || true
apt-get install -y kali-archive-keyring || true
apt-get update || true
apt-get install -y --no-install-recommends network-manager wpasupplicant openssh-server \
  iw iproute2 iputils-ping sudo nano less dnsmasq locales usbutils e2fsprogs curl wget rsync
apt-get install -y firmware-brcm80211 bluez bluez-firmware || apt-get install -y bluez || true
apt-get install -y ${TOOLS}

# ---------------- touch desktop: Xorg (framebuffer) + Openbox + tint2 panel + Onboard keyboard ----------------
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput xinit xauth openbox dbus-x11 \
  x11-xserver-utils tint2 onboard lxterminal pcmanfm
for p in xterm network-manager-gnome fonts-dejavu-core adwaita-icon-theme; do
  apt-get install -y --no-install-recommends "$p" || echo "WARN: optional package $p not installed"
done

useradd -m -s /bin/bash kali || true
for g in sudo audio video plugdev netdev input dialout bluetooth; do
  getent group "$g" >/dev/null && usermod -aG "$g" kali || true
done
echo 'kali:kali' | chpasswd
echo 'root:kali' | chpasswd

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-fbdev.conf <<'XEOF'
Section "ServerFlags"
  Option "AutoAddGPU" "false"
  Option "DontVTSwitch" "true"
EndSection
Section "Device"
  Identifier "fb0"
  Driver "fbdev"
  Option "fbdev" "/dev/fb0"
EndSection
XEOF
cat > /etc/X11/xorg.conf.d/40-touch.conf <<'XEOF'
Section "InputClass"
  Identifier "touchscreen"
  MatchIsTouchscreen "on"
  Driver "libinput"
EndSection
XEOF

cat > /usr/local/bin/kali-session <<'XEOF'
#!/bin/sh
# Runs as root inside xinit: tune the display, then start the desktop as user kali.
if command -v xset >/dev/null 2>&1; then xset s off; xset -dpms; xset s noblank; fi
install -d -o kali -g kali -m 700 /run/user/1000
exec runuser -u kali -- env HOME=/home/kali USER=kali LOGNAME=kali XDG_RUNTIME_DIR=/run/user/1000 LANG=C.UTF-8 DISPLAY=:0 \
  dbus-run-session -- openbox-session
XEOF
chmod 755 /usr/local/bin/kali-session

cat > /etc/systemd/system/kali-gui.service <<'XEOF'
[Unit]
Description=Kali touch desktop (Xorg + Openbox)
After=systemd-user-sessions.service systemd-udevd.service dbus.service getty@tty1.service
Conflicts=getty@tty1.service
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYReset=yes
TTYVHangup=yes
ExecStart=/usr/bin/xinit /usr/local/bin/kali-session -- /usr/bin/Xorg :0 vt1 -nolisten tcp -noreset
ExecStopPost=-/bin/systemctl --no-block start getty@tty1.service
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
XEOF

H=/home/kali
install -d -o kali -g kali "$H/.config" "$H/.config/openbox" "$H/.config/tint2"
cat > "$H/.config/openbox/autostart" <<'XEOF'
tint2 &
nm-applet &
onboard &
XEOF
cat > "$H/.config/tint2/tint2rc" <<'XEOF'
rounded = 0
border_width = 0
background_color = #202020 100
border_color = #000000 0
rounded = 4
border_width = 0
background_color = #404040 100
border_color = #000000 0
rounded = 4
border_width = 0
background_color = #606060 100
border_color = #000000 0
panel_items = LTSC
panel_size = 100% 64
panel_position = bottom center horizontal
panel_margin = 0 0
panel_padding = 4 4 4
panel_background_id = 1
panel_layer = top
wm_menu = 1
launcher_padding = 4 4 6
launcher_background_id = 0
launcher_icon_size = 48
launcher_item_app = /usr/share/applications/lxterminal.desktop
launcher_item_app = /usr/share/applications/pcmanfm.desktop
launcher_item_app = /usr/share/applications/onboard.desktop
taskbar_mode = single_desktop
taskbar_padding = 2 2 2
taskbar_background_id = 0
task_text = 0
task_icon = 1
task_maximum_size = 64 48
task_padding = 4 4
task_background_id = 2
task_active_background_id = 3
systray_padding = 4 4 4
systray_background_id = 0
systray_icon_size = 40
time1_format = %H:%M
time1_font = Sans 14
clock_font_color = #ffffff 100
clock_padding = 6 0
clock_background_id = 0
XEOF
chown -R kali:kali "$H/.config"

# ---------------- USB networking so you can always ssh in (phone = 172.16.42.1) ----------------
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
for r in /sys/class/usb_role/*/role; do [ -e "$r" ] && echo device > "$r" 2>/dev/null; done
n=0; while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n+1)); done
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
# first boot: grow the root filesystem to fill the whole internal storage
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
systemctl enable NetworkManager ssh dnsmasq || true
systemctl enable usb-gadget.service resize-root.service kali-gui.service
systemctl set-default multi-user.target

apt-get clean
rm -rf /var/lib/apt/lists/* /setup.sh
SETUP
chmod +x "$ROOT/setup.sh"
chroot "$ROOT" env TOOLS="$TOOLS" /setup.sh

# ---- smoke tests inside the finished rootfs (qemu-user): fail the build early if something is missing ----
for p in e2fsprogs xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput xinit openbox tint2 onboard lxterminal pcmanfm network-manager openssh-server; do
  chroot "$ROOT" dpkg -s "$p" 2>/dev/null | grep -q '^Status: install ok installed' || { echo "ERROR: package $p is not installed"; exit 1; }
done
for f in /usr/bin/Xorg /usr/bin/openbox-session /usr/bin/tint2 /usr/bin/onboard /usr/sbin/resize2fs /usr/sbin/mkfs.ext4 \
         /usr/lib/xorg/modules/drivers/fbdev_drv.so /usr/local/bin/kali-session /etc/systemd/system/kali-gui.service; do
  [ -e "$ROOT$f" ] || { echo "ERROR: $f is missing"; exit 1; }
done
chroot "$ROOT" /usr/bin/Xorg -version 2>&1 | head -3 || true
for u in kali-gui resize-root usb-gadget; do
  [ -e "$ROOT/etc/systemd/system/multi-user.target.wants/$u.service" ] || { echo "ERROR: $u.service is not enabled"; exit 1; }
done

# ---- merge kernel modules + firmware from the postmarketOS image ----
IMG=work/pmos/rootfs.img
file "$IMG" || true
if [ "$(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
  echo "pmOS rootfs is an Android sparse image -> simg2img"
  simg2img "$IMG" work/pmos/rootfs.raw
  IMG=work/pmos/rootfs.raw
fi
mkdir -p work/pmos-mnt
sfdisk -d "$IMG" || true
PMOS_OK=""
if mount -o ro,loop "$IMG" work/pmos-mnt 2>/dev/null; then
  if [ -d work/pmos-mnt/etc ]; then PMOS_OK=1; else umount work/pmos-mnt; fi
fi
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
findmnt -R "$ROOT" || true
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp"
chmod 1777 "$ROOT/tmp"

# ---- raw ext4 image labelled kali_root ----
# No metadata_csum: the old kernel inside TWRP corrupts filesystems that have it. Grown to the whole
# internal storage by the phone on first boot (resize-root.service).
USED=$(du -sm --apparent-size --one-file-system "$ROOT" | cut -f1)
SIZE=$(( USED * 120 / 100 + 300 ))
truncate -s "${SIZE}M" work/kali-root.img
mkfs.ext4 -F -q -L kali_root -m 1 -O ^metadata_csum,^64bit,^orphan_file -d "$ROOT" work/kali-root.img \
  || mkfs.ext4 -F -q -L kali_root -m 1 -O ^metadata_csum,^64bit -d "$ROOT" work/kali-root.img
e2fsck -fn work/kali-root.img
dumpe2fs -h work/kali-root.img 2>/dev/null | grep -Ei 'features|volume name|block count' || true
ls -la work/kali-root.img
