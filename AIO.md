# All-in-one zip (installs Kali to the internal storage)

Workflow: **build-kali-aio** (starts by itself on push, or Actions -> Run workflow).
Result (artifact `kali-a2corelte-aio`): `kali-a2corelte-aio.zip`

## Install
1. Download the artifact, unzip the GitHub wrapper, copy `kali-a2corelte-aio.zip` to the **microSD card**.
   The zip must be on the SD card: the install ERASES the internal storage (Android data, /sdcard).
2. Optional: put a text file `kali-wifi.txt` next to the zip. Line 1 = Wi-Fi name, line 2 = password.
3. TWRP -> Install -> pick the zip from the SD card (not from internal storage, not adb sideload).
4. Reboot to system. First boot grows the filesystem to the whole internal storage, then the touch
   desktop (Openbox + panel + on-screen keyboard) starts. Login `kali` / `kali`.

What it writes: BOOT (kernel + tiny initramfs) and USERDATA (Kali). SYSTEM is not touched; if the new
root cannot be mounted, the boot image falls back to an old root labelled `pmOS_root` on SYSTEM.
Do not use TWRP Wipe / Format Data afterwards.

Sources: `scripts/aio/` (build-rootfs.sh, make-boot.py, initramfs-init, make-zip.py, update-binary.sh).
