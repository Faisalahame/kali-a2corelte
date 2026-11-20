#!/usr/bin/env bash
# Builds the ALL-IN-ONE Kali zip for the Galaxy A2 Core:
#   * Kali arm64 rootfs WITH the touch desktop (Xorg fbdev + Openbox + tint2 + Onboard keyboard) baked in
#   * kernel modules + firmware merged in from the postmarketOS image built by build-pmos.sh
#   * ext4 image labelled kali_root (no metadata_csum, TWRP's old kernel corrupts those), grown to the whole
#     data partition on first boot
#   * small boot image (scripts/make-bootimg.py) that prefers LABEL=kali_root and falls back to LABEL=pmOS_root
#   * a TWRP zip that writes the image to USERDATA (whole internal storage) and must be flashed from a microSD card
# Must run as root. Needs out/boot.img and work/pmos/rootfs.img from scripts/build-pmos.sh.
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work out
exec > >(tee -a work/aio.log) 2>&1
TOOLS="${TOOLS:-kali-linux-core}"
ROOT="$PWD/work/kali-root"
OUTZIP="$PWD/out/kali-a2corelte-aio.zip"

cleanup() {
  for p in /proc/[0-9]*; do
    r=$(readlink "$p/root" 2>/dev/null || true)
    case "$r" in "$ROOT"|"$ROOT"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
  done
  sleep 1
  for m in dev sys proc; do umount -R -l "$ROOT/$m" 2>/dev/null || true; done
  umount work/pmos-mnt 2>/dev/null || true
  umount work/final-mnt 2>/dev/null || true
}
trap cleanup EXIT

[ -s out/boot.img ] || { echo "ERROR: out/boot.img (from build-pmos.sh) is missing"; exit 1; }
[ -s work/pmos/rootfs.img ] || { echo "ERROR: work/pmos/rootfs.img (from build-pmos.sh) is missing"; exit 1; }

apt-get install -y android-sdk-libsparse-utils e2fsprogs fdisk zip unzip zstd lz4 python3 || true

# ---------- 1. the small boot image (needs only out/boot.img) ----------
python3 scripts/make-bootimg.py out/boot.img scripts/initramfs-init.sh work/boot-aio.img
[ "$(stat -c %s work/boot-aio.img)" -le 33554432 ]

# ---------- 2. Kali rootfs ----------
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
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
echo kali-a2core > /etc/hostname
echo "127.0.1.1 kali-a2core" >> /etc/hosts
echo "LABEL=kali_root / ext4 defaults,noatime 0 1" > /etc/fstab
echo 'LANG=C.UTF-8' > /etc/default/locale

apt-get update || true
apt-get install -y kali-archive-keyring || true
apt-get update || true
apt-get install -y --no-install-recommends network-manager wpasupplicant openssh-server \
  iw iproute2 iputils-ping sudo nano less dnsmasq locales usbutils e2fsprogs systemd-timesyncd curl wget
apt-get install -y firmware-brcm80211 bluez bluez-firmware || apt-get install -y bluez || true
apt-get install -y ${TOOLS}

useradd -m -s /bin/bash kali || true
for g in sudo audio video plugdev netdev input dialout bluetooth; do
  getent group "$g" >/dev/null && usermod -aG "$g" kali || true
done
echo 'kali:kali' | chpasswd
echo 'root:kali' | chpasswd

# ================= touch desktop =================
# essential part: the build FAILS if these cannot be installed
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput xinit xauth openbox dbus-x11
# the rest of the desktop: also checked below, but one missing extra must not hide the others
for p in x11-xserver-utils tint2 onboard lxterminal xterm pcmanfm network-manager-gnome \
         dconf-gsettings-backend dconf-service fonts-dejavu-core adwaita-icon-theme; do
  apt-get install -y --no-install-recommends "$p" || echo "WARNING: could not install $p"
done

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

# NetworkManager: let the touch UI (nm-applet) change Wi-Fi without a polkit daemon
printf '[main]\nauth-polkit=false\n' > /etc/NetworkManager/conf.d/20-no-polkit.conf

install -d -o kali -g kali /home/kali/.config /home/kali/.config/openbox /home/kali/.config/tint2
cat > /home/kali/.config/openbox/autostart <<'XEOF'
tint2 &
nm-applet &
onboard &
( sleep 6; gsettings set org.onboard.window docking-enabled true; gsettings set org.onboard.window docking-edge bottom ) &
XEOF
# panel on TOP (the keyboard docks at the bottom): launchers, task list, tray, clock
cat > /home/kali/.config/tint2/tint2rc <<'XEOF'
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
panel_position = top center horizontal
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
chown -R kali:kali /home/kali/.config

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

# ================= USB networking, first-boot jobs =================
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
# first boot: grow the root filesystem to fill the whole data partition (online resize, e2fsprogs is installed)
cat > /etc/systemd/system/resize-root.service <<'RESIZE'
[Unit]
Description=Grow root filesystem to fill its partition (first boot only)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'resize2fs "$(findmnt -n -o SOURCE /)" && systemctl disable resize-root.service'
[Install]
WantedBy=multi-user.target
RESIZE
# first boot: new SSH host keys (the image is public, so its keys must not be reused)
cat > /etc/systemd/system/ssh-hostkeys.service <<'KEYS'
[Unit]
Description=Generate SSH host keys (first boot)
Before=ssh.service
ConditionFileNotEmpty=!/etc/ssh/ssh_host_ed25519_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
KEYS
# first boot: 1 GB swap file (the phone has < 1 GB RAM). Best effort: skipped if the kernel has no swap.
cat > /usr/local/sbin/kali-swap.sh <<'SWAP'
#!/bin/sh
[ -e /swapfile ] && exit 0
fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null || exit 0
chmod 600 /swapfile
if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  rm -f /swapfile
fi
exit 0
SWAP
chmod +x /usr/local/sbin/kali-swap.sh
cat > /etc/systemd/system/kali-swap.service <<'UNIT'
[Unit]
Description=Create a swap file (first boot)
After=resize-root.service
ConditionPathExists=!/swapfile
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kali-swap.sh
[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /etc/dnsmasq.d /etc/NetworkManager/conf.d
printf 'interface=usb0\nbind-dynamic\ndhcp-range=172.16.42.2,172.16.42.10,255.255.255.0,12h\n' > /etc/dnsmasq.d/usb.conf
printf '[keyfile]\nunmanaged-devices=interface-name:usb0\n' > /etc/NetworkManager/conf.d/10-usb0.conf
systemctl enable NetworkManager ssh usb-gadget.service dnsmasq resize-root.service ssh-hostkeys.service kali-swap.service systemd-timesyncd kali-gui.service || true

# the build must not silently produce an image without the desktop
for p in xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput xinit openbox tint2 onboard lxterminal pcmanfm network-manager-gnome e2fsprogs; do
  dpkg -s "$p" >/dev/null 2>&1 || { echo "MISSING PACKAGE: $p"; MISSING=1; }
done
[ -z "${MISSING:-}" ] || exit 1
test -x /usr/bin/Xorg -o -x /usr/lib/xorg/Xorg
test -x /usr/bin/openbox
test -x /usr/sbin/resize2fs || test -x /sbin/resize2fs
test -e /etc/systemd/system/multi-user.target.wants/kali-gui.service

rm -f /etc/ssh/ssh_host_*
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/* /setup.sh
SETUP
chmod +x "$ROOT/setup.sh"
chroot "$ROOT" env TOOLS="$TOOLS" /setup.sh

# ---------- 3. merge kernel modules + firmware from the postmarketOS image ----------
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
for d in lib usr/lib; do
  [ -d "work/pmos-mnt/$d/modules" ] && mkdir -p "$ROOT/usr/lib/modules" && cp -a "work/pmos-mnt/$d/modules/." "$ROOT/usr/lib/modules/"
  [ -d "work/pmos-mnt/$d/firmware" ] && mkdir -p "$ROOT/usr/lib/firmware" && cp -an "work/pmos-mnt/$d/firmware/." "$ROOT/usr/lib/firmware/"
done
for d in etc/modules-load.d etc/modprobe.d; do
  [ -d "work/pmos-mnt/$d" ] && mkdir -p "$ROOT/$d" && cp -an "work/pmos-mnt/$d/." "$ROOT/$d/"
done
for v in "$ROOT"/usr/lib/modules/*; do [ -d "$v" ] && depmod -b "$ROOT" "$(basename "$v")"; done
ls "$ROOT/usr/lib/modules"
[ -n "$(ls "$ROOT/usr/lib/modules")" ] || { echo "ERROR: no kernel modules were merged"; exit 1; }

rm -f "$ROOT/etc/resolv.conf" "$ROOT/usr/bin/qemu-aarch64-static"
cleanup
findmnt -R "$ROOT" || true
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" "$ROOT/mnt" "$ROOT/media"
chmod 1777 "$ROOT/tmp"

# ---------- 4. ext4 image: label kali_root, no metadata_csum ----------
USED=$(du -sm --apparent-size --one-file-system "$ROOT" | cut -f1)
SIZE=$(( USED * 115 / 100 + 300 ))
echo "rootfs: ${USED} MB used, image ${SIZE} MB"
truncate -s "${SIZE}M" work/kali-root.img
mkfs.ext4 -F -q -b 4096 -L kali_root -m 1 -O ^metadata_csum,^64bit,^orphan_file -d "$ROOT" work/kali-root.img \
  || mkfs.ext4 -F -q -b 4096 -L kali_root -m 1 -O ^metadata_csum,^64bit -d "$ROOT" work/kali-root.img
e2fsck -fn work/kali-root.img
dumpe2fs -h work/kali-root.img 2>/dev/null | grep -iE 'volume name|features|block count' || true
dumpe2fs -h work/kali-root.img 2>/dev/null | grep -i features | grep -qi metadata_csum && { echo "ERROR: image has metadata_csum"; exit 1; }
dumpe2fs -h work/kali-root.img 2>/dev/null | grep -qi 'volume name: *kali_root'

# look inside the finished image before it goes into a zip
mkdir -p work/final-mnt
mount -o ro,loop work/kali-root.img work/final-mnt
for f in sbin/init usr/local/bin/kali-session etc/systemd/system/kali-gui.service etc/X11/xorg.conf.d/10-fbdev.conf home/kali/.config/tint2/tint2rc; do
  [ -e "work/final-mnt/$f" ] || { echo "ERROR: $f missing in the image"; exit 1; }
done
[ -x work/final-mnt/usr/bin/openbox ] && ls work/final-mnt/usr/lib/xorg/Xorg work/final-mnt/usr/bin/Xorg 2>/dev/null | head -2
grep -q '^LABEL=kali_root' work/final-mnt/etc/fstab
umount work/final-mnt

# ---------- 5. the zip ----------
python3 scripts/mk-aio-zip.py "$OUTZIP" work/boot-aio.img work/kali-root.img scripts/aio-update-binary.sh
ls -la out
Z=$(stat -c %s "$OUTZIP")
echo "zip size: $((Z/1048576)) MB"
[ "$Z" -lt 2040109465 ] || echo "WARNING: zip is over 1.9 GiB, GitHub release upload will be refused"
# keep only the flashable zip in out/ (the workflow uploads out/*)
mv out/boot.img work/boot.img.built
ls -la out
