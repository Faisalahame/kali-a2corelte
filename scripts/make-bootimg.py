#!/usr/bin/env python3
"""Turn the postmarketOS boot.img into the small boot image the Galaxy A2 Core bootloader accepts.

usage: make-bootimg.py PMOS_BOOT.img INIT_SCRIPT OUT.img

What it does (this is exactly what the hand-made boot-v13.img did):
  * keeps the kernel (raw arm64 Image, gunzipped if needed), device tree, load addresses and page size
  * replaces the 20+ MB postmarketOS initramfs by a tiny one: busybox + musl taken from the original
    initramfs, plus our own /init (which mounts LABEL=kali_root, or LABEL=pmOS_root as fallback)
  * sets the kernel command line the phone needs (visible console, clocks/power domains kept on)
  * appends the SEANDROIDENFORCE marker Samsung's bootloader expects, and checks the result fits BOOT (32 MiB)
"""
import gzip, hashlib, lzma, shutil, stat, struct, subprocess, sys, tempfile, os

CMDLINE = ("console=tty0 ignore_loglevel printk.time=1 clk_ignore_unused pd_ignore_unused "
           "initcall_blacklist=efifb_driver_init pmos_rootfsopts=defaults")
BOOT_LIMIT = 32 * 1024 * 1024
MARKER = b"SEANDROIDENFORCE"


def die(msg):
    sys.exit("ERROR: " + msg)


def decompress(blob):
    if blob[:2] == b"\x1f\x8b":
        return gzip.decompress(blob)
    if blob[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(blob)
    if blob[:4] == b"\x28\xb5\x2f\xfd":
        return subprocess.run(["zstd", "-dc"], input=blob, stdout=subprocess.PIPE, check=True).stdout
    if blob[:4] in (b"\x02\x21\x4c\x18", b"\x04\x22\x4d\x18"):
        return subprocess.run(["lz4", "-dc"], input=blob, stdout=subprocess.PIPE, check=True).stdout
    return blob  # plain cpio


def parse_cpio(rd):
    """yield (name, mode, data) for every entry of one or more concatenated newc archives"""
    p = 0
    while p < len(rd):
        if rd[p:p + 6] != b"070701":
            # padding between concatenated archives
            nxt = rd.find(b"070701", p)
            if nxt < 0:
                return
            p = nxt
        h = rd[p:p + 110]
        f = lambda i: int(h[6 + 8 * i:14 + 8 * i], 16)
        mode, fsz, nsz = f(1), f(6), f(11)
        name = rd[p + 110:p + 110 + nsz - 1].decode()
        p = (p + 110 + nsz + 3) & ~3
        data = rd[p:p + fsz]
        p = (p + fsz + 3) & ~3
        if name == "TRAILER!!!":
            continue
        yield name.lstrip("./"), mode, data


def newc(entries):
    """entries: list of (name, mode, data, rdev_major, rdev_minor); inode numbers start at 2 like before"""
    out = b""
    for ino, (name, mode, data, rmaj, rmin) in enumerate(entries + [("TRAILER!!!", 0, b"", 0, 0)], start=2):
        nm = name.encode() + b"\0"
        nlink = 2 if stat.S_ISDIR(mode) else 1
        hdr = b"070701" + b"".join(b"%08X" % v for v in
              (ino, mode, 0, 0, nlink, 0, len(data), 0, 0, rmaj, rmin, len(nm), 0))
        out += hdr + nm + b"\0" * ((-(110 + len(nm))) % 4) + data + b"\0" * ((-len(data)) % 4)
    return out + b"\0" * ((-len(out)) % 512)


def main():
    if len(sys.argv) != 4:
        die(__doc__)
    src, init_path, dst = sys.argv[1:4]
    d = open(src, "rb").read()
    if d[:8] != b"ANDROID!":
        die("not an Android boot image: " + src)
    ks, ka, rs, ra, ss, sa, ta, ps, dts, ver = struct.unpack("<10I", d[8:48])
    pg = lambda n: (n + ps - 1) // ps * ps
    ko = ps
    ro = ko + pg(ks)
    so = ro + pg(rs)
    do = so + pg(ss)
    kernel = d[ko:ko + ks]
    ramdisk = d[ro:ro + rs]
    second = d[so:so + ss]
    dt = d[do:do + dts]
    print(f"input: page {ps}, kernel {ks}, ramdisk {rs}, second {ss}, dt {dts}")
    if kernel[:2] == b"\x1f\x8b":
        kernel = gzip.decompress(kernel)
        print("kernel was gzip-compressed, now", len(kernel))
    if kernel[0x38:0x3c] != b"ARM\x64":
        die("kernel is not a raw arm64 Image (magic at 0x38 is %r). Is a DTB appended or is it compressed differently?" % kernel[0x38:0x3c])
    ks = len(kernel)

    # --- pick busybox + musl out of the original initramfs ---
    bb = ld = None
    libc_link = None
    for name, mode, data in parse_cpio(decompress(ramdisk)):
        base = os.path.basename(name)
        if stat.S_ISREG(mode) and base == "busybox" and len(data) > 300000 and (bb is None or len(data) > len(bb)):
            bb = data
        elif stat.S_ISREG(mode) and base == "ld-musl-aarch64.so.1":
            ld = data
        elif stat.S_ISLNK(mode) and base == "libc.musl-aarch64.so.1":
            libc_link = data.decode()
    if bb is None or ld is None:
        die("busybox and/or the musl loader were not found in the original initramfs")
    print(f"busybox {len(bb)} bytes, musl loader {len(ld)} bytes")

    S_DIR, S_LNK, S_REG, S_CHR = 0o040755, 0o120777, 0o100755, 0o020000
    init = open(init_path, "rb").read()
    entries = [
        (".", S_DIR, b"", 0, 0),
        ("bin", S_LNK, b"usr/bin", 0, 0),
        ("dev", S_DIR, b"", 0, 0),
        ("etc", S_DIR, b"", 0, 0),
        ("init", S_REG, init, 0, 0),
        ("lib", S_LNK, b"usr/lib", 0, 0),
        ("proc", S_DIR, b"", 0, 0),
        ("run", S_DIR, b"", 0, 0),
        ("sbin", S_LNK, b"usr/bin", 0, 0),
        ("sys", S_DIR, b"", 0, 0),
        ("sysroot", S_DIR, b"", 0, 0),
        ("tmp", S_DIR, b"", 0, 0),
        ("usr", S_DIR, b"", 0, 0),
        ("usr/bin", S_DIR, b"", 0, 0),
        ("usr/lib", S_DIR, b"", 0, 0),
        ("usr/sbin", S_DIR, b"", 0, 0),
        ("usr/bin/busybox", S_REG, bb, 0, 0),
        ("usr/lib/ld-musl-aarch64.so.1", S_REG, ld, 0, 0),
        ("usr/lib/libc.musl-aarch64.so.1", S_LNK, b"ld-musl-aarch64.so.1", 0, 0),
        ("dev/console", S_CHR | 0o600, b"", 5, 1),
        ("dev/null", S_CHR | 0o666, b"", 1, 3),
    ]
    ramdisk_new = gzip.compress(newc(entries), 9, mtime=0)
    print("new initramfs:", len(ramdisk_new), "bytes")

    hdr = bytearray(d[:ps])
    hdr[8:12] = struct.pack("<I", ks)
    hdr[16:20] = struct.pack("<I", len(ramdisk_new))
    cmd = CMDLINE.encode()
    assert len(cmd) < 512
    hdr[64:64 + 512] = cmd + b"\0" * (512 - len(cmd))
    hdr[608:608 + 1024] = b"\0" * 1024           # extra cmdline
    sha = hashlib.sha1()
    for blob, sz in ((kernel, ks), (ramdisk_new, len(ramdisk_new)), (second, ss), (dt, dts)):
        sha.update(blob)
        sha.update(struct.pack("<I", sz))
    hdr[576:608] = sha.digest() + b"\0" * 12

    padto = lambda b: b + b"\0" * (pg(len(b)) - len(b))
    img = bytes(hdr) + padto(kernel) + padto(ramdisk_new) + (padto(second) if ss else b"") + padto(dt) + MARKER
    print("output:", len(img), "bytes; BOOT partition is", BOOT_LIMIT)
    if len(img) > BOOT_LIMIT:
        die("boot image does not fit into the 32 MiB BOOT partition")
    open(dst, "wb").write(img)
    print("md5", hashlib.md5(img).hexdigest())


if __name__ == "__main__":
    main()
