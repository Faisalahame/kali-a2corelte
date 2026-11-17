#!/usr/bin/env bash
# Builds the close-to-mainline Exynos 7870 kernel + initramfs + boot.img for samsung-a2corelte
# using postmarketOS' pmbootstrap (it already knows this phone's boot image format).
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/pmos out
exec > >(tee -a work/pmos.log) 2>&1
DEVICE=samsung-a2corelte
KERNEL_PKG=linux-postmarketos-exynos7870

# pmbootstrap is no longer on PyPI (all versions yanked) -> install from git
rm -rf "$HOME/pmbootstrap"
git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git "$HOME/pmbootstrap"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --break-system-packages "$HOME/pmbootstrap" \
  || ln -sf "$HOME/pmbootstrap/pmbootstrap.py" "$HOME/.local/bin/pmbootstrap"
pmbootstrap --version

# pmaports (device + kernel packages) in pmbootstrap's default location
WORK="$HOME/.local/var/pmbootstrap"
PMAPORTS="$WORK/cache_git/pmaports"
if [ ! -d "$PMAPORTS/.git" ]; then
  mkdir -p "$(dirname "$PMAPORTS")"
  git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS"
fi
git -C "$PMAPORTS" remote -v
git -C "$PMAPORTS" log --oneline -n 1

# The work folder normally gets its "version" file from "pmbootstrap init".
# We created it by hand (git clone above), so write the version file ourselves,
# otherwise pmbootstrap says "work folder version needs to be migrated".
WORKVER=$(python3 -c 'import pmb.config as c; print(c.work_version)' 2>/dev/null || echo 8)
echo "work folder version: $WORKVER"
echo "$WORKVER" > "$WORK/version"

# pmbootstrap refuses to run (even "config") until a config file exists,
# and "pmbootstrap init" is interactive -> write a minimal config ourselves.
mkdir -p "$HOME/.config"
cat > "$HOME/.config/pmbootstrap_v3.cfg" <<EOF
[pmbootstrap]
device = $DEVICE
ui = none
user = kali
EOF

# Make sure the device + kernel packages exist in this pmaports checkout.
# If a package was moved to another category it is found anywhere under device/;
# if it was deleted, restore it from git history.
echo "== pmaports device categories =="
ls "$PMAPORTS/device"
restore_pkg() {
  local pkg="$1" found c p d
  found=$(find "$PMAPORTS/device" -maxdepth 2 -type d -name "$pkg" | head -n1)
  if [ -n "$found" ]; then
    echo "FOUND $pkg at $found"
    return 0
  fi
  echo "$pkg not in current pmaports tree, searching git history"
  c=$(git -C "$PMAPORTS" log --all --diff-filter=D --format=%H -n1 -- "device/*/$pkg/APKBUILD" || true)
  if [ -z "$c" ]; then
    echo "ERROR: $pkg is not in pmaports and was never deleted from it"
    return 1
  fi
  git -C "$PMAPORTS" show --stat --format='%h %an %ad%n%B' "$c" | head -n 30
  p=$(git -C "$PMAPORTS" show --name-only --format= "$c" -- "device/*/$pkg/APKBUILD" | head -n1)
  d=$(dirname "$p")
  git -C "$PMAPORTS" checkout "$c^" -- "$d"
  echo "RESTORED $pkg from $c^ into $d"
}
restore_pkg "device-$DEVICE"
restore_pkg "$KERNEL_PKG" || true
find "$PMAPORTS/device" -maxdepth 2 \( -name "device-$DEVICE" -o -name "$KERNEL_PKG" \)

pmbootstrap -y config device "$DEVICE"
pmbootstrap -y config ui none
pmbootstrap -y config user kali
pmbootstrap -y config hostname kali-a2core
pmbootstrap config || true
pmbootstrap -y install --password kali

rm -rf /tmp/pmos-export
pmbootstrap -y export /tmp/pmos-export
ls -laL /tmp/pmos-export

BOOT=$(ls /tmp/pmos-export/boot.img* | head -n1)
cp -L "$BOOT" out/boot.img
cp -L "/tmp/pmos-export/${DEVICE}.img" work/pmos/rootfs.img
ls -la out work/pmos
