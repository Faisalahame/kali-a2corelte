# kali-a2corelte — native Kali Linux for the Samsung Galaxy A2 Core

Real Kali Linux (not Android) on the SM-A260G, using the close-to-mainline
Exynos 7870 kernel that postmarketOS maintains for `samsung-a2corelte`.

**Status: first draft, never booted.** Nothing here is tested on hardware.
The kernel project lists this phone as "testing". Which parts work
(Wi-Fi, Bluetooth, modem/calls, camera, audio, battery readout) is unknown
until you boot it. Expect to iterate with logs.

## What the workflow builds
- `boot.img` — mainline kernel + initramfs (from pmbootstrap, samsung-a2corelte)
- `kali-rootfs.tar.gz` — Kali arm64 rootfs, kernel modules + firmware merged in
- Login: user `kali` / password `kali` (change it). SSH over USB at 172.16.42.1.

Run it: Actions tab -> build-kali-a2corelte -> Run workflow
(`tools`: kali-linux-core, kali-tools-top10 ...; `ui`: none or phosh).

## Flashing (this ERASES /data — back up first)
Files go in /sdcard/Download on the phone running Termux.

1. Boot the phone into TWRP, flash `boot.img` to the BOOT partition
   (TWRP: Install -> Install Image -> boot).
2. In TWRP, format the userdata partition as ext4 with label `pmOS_root`:
       adb shell "umount /data; mkfs.ext4 -F -L pmOS_root /dev/block/mmcblk0p26"
       adb shell "mkdir -p /mnt/k; mount /dev/block/mmcblk0p26 /mnt/k"
3. Stream the rootfs in:
       cat /sdcard/Download/kali-rootfs.tar.gz | adb shell "tar -xzpf - -C /mnt/k"
       adb shell "sync; umount /mnt/k"
4. Reboot. If the screen stays black, wait 2 minutes, plug USB into a PC and
   `ssh kali@172.16.42.1`.

Restore Android by flashing your stock boot/system images again.
