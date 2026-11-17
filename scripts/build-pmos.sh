#!/usr/bin/env bash
# Builds the close-to-mainline Exynos 7870 kernel + initramfs + boot.img for the Galaxy A2 Core
# using postmarketOS' pmbootstrap.
# NOTE: postmarketOS dropped the per-phone package device-samsung-a2corelte in May 2026
# ("Switch to generic port samsung-exynos7"), so we build the generic samsung-exynos7 port with its
# close-to-mainline exynos7870 kernel. If that port is missing we fall back to the old package.
set -euxo pipefail
cd "$(dirname "$0")/.."
mkdir -p work/pmos out
exec > >(tee -a work/pmos.log) 2>&1

WORK="$HOME/.local/var/pmbootstrap"
PMAPORTS="$WORK/cache_git/pmaports"

# On any failure print the interesting lines of pmbootstrap's own log (the console output hides them)
on_err() {
  set +x
  echo "== pmbootstrap log: error lines =="
  grep -aiE 'error|unable|no such|required by|conflict|not found|fail|satisf|breaks' "$WORK/log.txt" 2>/dev/null \
    | tail -n 30 | cut -c1-300 | tee work/pmb-errors.log || true
}
trap on_err ERR

# pmbootstrap is no longer on PyPI (all versions yanked) -> install from git
rm -rf "$HOME/pmbootstrap"
git clone --depth=1 https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git "$HOME/pmbootstrap"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
python3 -m pip install --user --break-system-packages "$HOME/pmbootstrap" \
  || ln -sf "$HOME/pmbootstrap/pmbootstrap.py" "$HOME/.local/bin/pmbootstrap"
pmbootstrap --version

# pmaports (device + kernel packages) in pmbootstrap's default location
if [ ! -d "$PMAPORTS/.git" ]; then
  mkdir -p "$(dirname "$PMAPORTS")"
  git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMAPORTS"
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

echo "== pmaports device categories =="
ls "$PMAPORTS/device"
echo "== samsung/exynos7 related packages =="
find "$PMAPORTS/device" -maxdepth 2 \( -name '*exynos7*' -o -name '*a2core*' \)

GENERIC=$(find "$PMAPORTS/device" -maxdepth 2 -type d -name device-samsung-exynos7 | head -n1)
if [ -n "$GENERIC" ]; then
  DEVICE=samsung-exynos7
  echo "== generic port: $GENERIC =="
  ls -la "$GENERIC"
  cat "$GENERIC/APKBUILD"
  cat "$GENERIC/deviceinfo" || true
  grep -rIn "a2core\|7870" "$GENERIC" || true
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
pmbootstrap config || true
pmbootstrap -y install --password kali

rm -rf /tmp/pmos-export
pmbootstrap -y export /tmp/pmos-export
ls -laL /tmp/pmos-export

BOOT=$(ls /tmp/pmos-export/boot.img* | head -n1)
cp -L "$BOOT" out/boot.img
cp -L "/tmp/pmos-export/${DEVICE}.img" work/pmos/rootfs.img
ls -la out work/pmos
