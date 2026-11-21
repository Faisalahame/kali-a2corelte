#!/usr/bin/env bash
# Builds the close-to-mainline Exynos 7870 kernel + initramfs + boot.img for the Galaxy A2 Core
# using postmarketOS' pmbootstrap.
# NOTE: postmarketOS dropped the per-phone package device-samsung-a2corelte in May 2026
# ("Switch to generic port samsung-exynos7"). The generic port has no Android boot.img support,
# but the old per-phone package had it. So we build the generic port (with its close-to-mainline
# exynos7870 kernel) and copy the old a2corelte boot.img settings (offsets, page size, cmdline,
# dtb, mkbootimg/dtbtool) from pmaports git history into it. That makes pmbootstrap produce
# the same kind of boot.img the old a2corelte package produced.
# The pmOS rootfs itself is NOT shipped: only its kernel modules, firmware and boot.img are used.
# So the service manager inside it does not matter (see the OpenRC fallback below).
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/pmos out
exec > >(tee -a work/pmos.log) 2>&1

WORK="$HOME/.local/var/pmbootstrap"
PMAPORTS="$WORK/cache_git/pmaports"

# On any failure print the interesting lines of pmbootstrap's own log
on_err() {
  set +x
  echo "== pmbootstrap log: error lines =="
  grep -aiE 'error|unable to select|no such package|required by|conflict|not found|failed|satisf|breaks' "$WORK/log.txt" 2>/dev/null \
    | grep -av 'APKINDEX\|Unable to find\|Error relocating' | tail -n 30 | cut -c1-300 | tee work/pmb-errors.log || true
}
trap on_err ERR

# gitlab.postmarketos.org sometimes answers 502 ("GitLab is not responding"): retry, then try the gitlab.com mirror
clone_retry() {
  local dest="$1" depth="$2" name="$3" u n
  for u in "https://gitlab.postmarketos.org/postmarketOS/$name.git" "https://gitlab.com/postmarketOS/$name.git"; do
    for n in 1 2 3 4 5; do
      rm -rf "$dest"
      if git clone ${depth:+--depth=1} "$u" "$dest"; then return 0; fi
      echo "WARN: clone of $u failed (try $n/5), waiting"; sleep $((n*20))
    done
  done
  echo "ERROR: could not clone $name from any server"; return 1
}

# pmbootstrap is no longer on PyPI (all versions yanked) -> install from git
clone_retry "$HOME/pmbootstrap" 1 pmbootstrap
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --break-system-packages "$HOME/pmbootstrap" \
  || ln -sf "$HOME/pmbootstrap/pmbootstrap.py" "$HOME/.local/bin/pmbootstrap"
pmbootstrap --version

# pmaports (device + kernel packages) in pmbootstrap's default location
if [ ! -d "$PMAPORTS/.git" ]; then
  mkdir -p "$(dirname "$PMAPORTS")"
  clone_retry "$PMAPORTS" "" pmaports
fi
git -C "$PMAPORTS" remote -v
git -C "$PMAPORTS" log --oneline -n 1

# The work folder normally gets its "version" file from "pmbootstrap init".
WORKVER=$(python3 -c 'import pmb.config as c; print(c.work_version)' 2>/dev/null || echo 8)
echo "$WORKVER" > "$WORK/version"

restore_pkg() {
  local pkg="$1" found c p d
  found=$(find "$PMAPORTS/device" -maxdepth 2 -type d -name "$pkg" | head -n1)
  if [ -n "$found" ]; then
    echo "FOUND $pkg at $found"
    return 0
  fi
  c=$(git -C "$PMAPORTS" log --all --diff-filter=D --format=%H -n1 -- "device/*/$pkg/APKBUILD" || true)
  [ -n "$c" ] || { echo "ERROR: $pkg is not in pmaports and was never deleted from it"; return 1; }
  p=$(git -C "$PMAPORTS" show --name-only --format= "$c" -- "device/*/$pkg/APKBUILD" | head -n1)
  d=$(dirname "$p")
  git -C "$PMAPORTS" checkout "$c^" -- "$d"
  echo "RESTORED $pkg from $c^ into $d"
}

GENERIC=$(find "$PMAPORTS/device" -maxdepth 2 -type d -name device-samsung-exynos7 | head -n1)
if [ -n "$GENERIC" ]; then
  DEVICE=samsung-exynos7
else
  DEVICE=samsung-a2corelte
  restore_pkg "device-$DEVICE"
  restore_pkg linux-postmarketos-exynos7870 || true
fi
echo "DEVICE=$DEVICE"

# pmbootstrap refuses to run (even "config") until a config file exists,
# and "pmbootstrap init" is interactive -> write a minimal config ourselves.
mkdir -p "$HOME/.config"
cat > "$HOME/.config/pmbootstrap_v3.cfg" <<EOF
[pmbootstrap]
device = $DEVICE
ui = none
user = kali
EOF

pmbootstrap -y config device "$DEVICE"
pmbootstrap -y config ui none
pmbootstrap -y config user kali
pmbootstrap -y config hostname kali-a2core
# close-to-mainline Exynos 7870 kernel variant of the generic port
pmbootstrap -y config kernel exynos7870 || echo "WARN: kernel option 'exynos7870' not accepted, keeping default"

if [ "$DEVICE" = samsung-exynos7 ]; then
  # ---- give the generic port the old a2corelte Android boot.img settings ----
  OLDC=$(git -C "$PMAPORTS" log --all --diff-filter=D --format=%H -n1 -- 'device/*/device-samsung-a2corelte/APKBUILD' || true)
  if [ -n "$OLDC" ]; then
    OLDP=$(git -C "$PMAPORTS" show --name-only --format= "$OLDC" -- 'device/*/device-samsung-a2corelte/deviceinfo' | head -n1)
    OLDD=$(dirname "$OLDP")
    git -C "$PMAPORTS" show "$OLDC^:$OLDP" > work/old-deviceinfo
    git -C "$PMAPORTS" show "$OLDC^:$OLDD/APKBUILD" > work/old-APKBUILD
    echo "===== OLD a2corelte deviceinfo ====="; cat work/old-deviceinfo
    echo "===== OLD a2corelte APKBUILD ====="; cat work/old-APKBUILD
    grep -E '^deviceinfo_(flash_|bootimg_|generate_bootimg|dtb|kernel_cmdline|header_version|append_dtb)' work/old-deviceinfo > work/old-keys || true
    echo "===== keys copied into generic deviceinfo ====="; cat work/old-keys
    if [ -s work/old-keys ]; then
      cut -d= -f1 work/old-keys | while read -r k; do sed -i "/^$k=/d" "$GENERIC/deviceinfo"; done
      cat work/old-keys >> "$GENERIC/deviceinfo"
    fi
  else
    echo "WARN: could not find the old a2corelte package in pmaports history"
  fi
  # tools that mkinitfs needs inside the rootfs to create boot.img (the old package depended on these)
  sed -i '0,/^\tsystemd-boot$/s//\tsystemd-boot\n\tmkbootimg\n\tdtbtool-exynos\n\tmesa-dri-simpledrm/' "$GENERIC/APKBUILD"
  # bump pkgrel so pmbootstrap builds our modified package instead of using the mirror's binary
  sed -i 's/^pkgrel=.*/pkgrel=99/' "$GENERIC/APKBUILD"
  pmbootstrap -y checksum device-samsung-exynos7
  echo "===== patched generic deviceinfo ====="; cat "$GENERIC/deviceinfo"
  echo "===== patched generic APKBUILD (head) ====="; head -n 25 "$GENERIC/APKBUILD"
fi

pmbootstrap config || true

# First try the default (systemd on current pmaports). If installing the rootfs fails (the 2026-11-21 run died
# in apk with "failed to commit usr/bin/udevadm / usr/sbin/init" from the systemd-edge repo), retry once with
# OpenRC. We only take kernel modules, firmware and boot.img from this rootfs, so the service manager is irrelevant.
if ! pmbootstrap -y install --password kali; then
  echo "WARN: pmbootstrap install failed with the default service manager -> retrying with OpenRC"
  cp -f "$WORK/log.txt" work/pmb-install-systemd-attempt.log 2>/dev/null || true
  pmbootstrap -y zap || true
  pmbootstrap -y config service_manager openrc \
    || pmbootstrap -y config systemd never \
    || echo "WARN: neither 'service_manager openrc' nor 'systemd never' was accepted by this pmbootstrap"
  pmbootstrap config | grep -iE 'service_manager|systemd' || true
  pmbootstrap -y install --password kali
fi

CH="$WORK/chroot_rootfs_$DEVICE"
echo "== rootfs /boot =="
sudo ls -la "$CH/boot" || true
sudo find "$CH/boot" "$CH/usr/share/dtb" -name '*a2corelte*' 2>/dev/null | head || true

rm -rf /tmp/pmos-export
pmbootstrap -y export /tmp/pmos-export
ls -laL /tmp/pmos-export

BOOT=$(ls /tmp/pmos-export/boot.img* 2>/dev/null | head -n1 || true)
if [ -z "$BOOT" ]; then
  echo "ERROR: pmbootstrap did not produce a boot.img (see the old deviceinfo / patched deviceinfo above)"
  cp -L /tmp/pmos-export/vmlinuz /tmp/pmos-export/initramfs out/ || true
  exit 1
fi
cp -L "$BOOT" out/boot.img
cp -L "/tmp/pmos-export/${DEVICE}.img" work/pmos/rootfs.img
ls -la out work/pmos
