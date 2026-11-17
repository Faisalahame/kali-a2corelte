#!/usr/bin/env python3
"""Build the TWRP-flashable zip.

usage: mkzip.py OUT.zip BOOT.img DISK.img update-binary-template

Layout of the zip:
  kali/boot.img    stored (no compression), data start aligned to ALIGN bytes, padded to ALIGN
  kali/disk.img    stored (no compression), data start aligned to ALIGN bytes
  META-INF/com/google/android/update-binary   template with the offsets/sizes/md5s filled in
  META-INF/com/google/android/updater-script  (dummy, some recoveries want it to exist)

Because the images are stored and aligned, the installer on the phone can copy them out of the
zip with a plain `dd if=zip skip=N count=M` - it needs no unzip.
"""
import hashlib
import struct
import sys
import zipfile

ALIGN = 32768
CHUNK = 8 * 1024 * 1024


def padded_size(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def md5_padded(path):
    h = hashlib.md5()
    n = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            n += len(b)
    pad = padded_size(n) - n
    h.update(b"\0" * pad)
    return h.hexdigest(), padded_size(n)


def add_aligned(zf, arcname, path, size):
    """Write `path` (zero-padded to `size`) as a stored entry whose data starts on an ALIGN boundary."""
    zi = zipfile.ZipInfo(arcname, date_time=(2026, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_STORED
    zi.external_attr = 0o644 << 16
    zi.file_size = size
    name_len = len(arcname.encode("utf-8"))
    base = zf.fp.tell() + 30 + name_len
    pad = (-(base + 4)) % ALIGN
    # extra field: id 0xD935 (the one zipalign uses), 2-byte length, then `pad` zero bytes
    zi.extra = struct.pack("<HH", 0xD935, pad) + b"\0" * pad
    written = 0
    with zf.open(zi, "w") as out, open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            out.write(b)
            written += len(b)
        tail = size - written
        while tail > 0:
            n = min(tail, CHUNK)
            out.write(b"\0" * n)
            tail -= n
    return zi


def data_offset(zip_path, zi):
    """Where the (stored) data of `zi` really starts, read from the local header on disk."""
    with open(zip_path, "rb") as f:
        f.seek(zi.header_offset)
        hdr = f.read(30)
    sig, _v, _flags, method, _t, _d, _crc, csize, usize, nlen, elen = struct.unpack("<4sHHHHHLLLHH", hdr)
    assert sig == b"PK\x03\x04", "bad local header"
    assert method == 0, "entry is not stored"
    return zi.header_offset + 30 + nlen + elen


def main():
    out, boot, disk, template = sys.argv[1:5]

    boot_md5, boot_size = md5_padded(boot)
    disk_md5, disk_size = md5_padded(disk)
    assert disk_size % ALIGN == 0 and boot_size % ALIGN == 0

    with zipfile.ZipFile(out, "w", allowZip64=True) as zf:
        zi_boot = add_aligned(zf, "kali/boot.img", boot, boot_size)
        zi_disk = add_aligned(zf, "kali/disk.img", disk, disk_size)
        zf.fp.flush()
    # header_offset values are final once the entries are written; compute the real data offsets
    boot_off = data_offset(out, zi_boot)
    disk_off = data_offset(out, zi_disk)
    for name, off in (("boot", boot_off), ("disk", disk_off)):
        if off % ALIGN:
            sys.exit("data of %s is not aligned (offset %d)" % (name, off))

    values = {
        "BOOT_SKIP": boot_off // ALIGN,
        "BOOT_BLOCKS": boot_size // ALIGN,
        "BOOT_KB": boot_size // 1024,
        "BOOT_MD5": boot_md5,
        "DISK_SKIP": disk_off // ALIGN,
        "DISK_BLOCKS": disk_size // ALIGN,
        "DISK_KB": disk_size // 1024,
        "DISK_MD5": disk_md5,
    }
    script = open(template, "r", encoding="utf-8").read()
    for k, v in values.items():
        script = script.replace("@%s@" % k, str(v))
    if "@" in "".join(l for l in script.splitlines() if l.startswith(("BOOT_", "DISK_"))):
        sys.exit("unfilled placeholder in update-binary")

    with zipfile.ZipFile(out, "a", allowZip64=True) as zf:
        ub = zipfile.ZipInfo("META-INF/com/google/android/update-binary", date_time=(2026, 1, 1, 0, 0, 0))
        ub.compress_type = zipfile.ZIP_DEFLATED
        ub.external_attr = 0o755 << 16
        zf.writestr(ub, script.encode("utf-8"))
        us = zipfile.ZipInfo("META-INF/com/google/android/updater-script", date_time=(2026, 1, 1, 0, 0, 0))
        us.compress_type = zipfile.ZIP_DEFLATED
        us.external_attr = 0o644 << 16
        zf.writestr(us, b"# intentionally empty - the installer logic is in update-binary\n")

    # end-to-end check: read the images back out of the finished zip at the offsets the installer will use
    for name, off, size, want in (("boot", boot_off, boot_size, boot_md5), ("disk", disk_off, disk_size, disk_md5)):
        h = hashlib.md5()
        with open(out, "rb") as f:
            f.seek(off)
            left = size
            while left:
                b = f.read(min(CHUNK, left))
                if not b:
                    sys.exit("zip is truncated")
                h.update(b)
                left -= len(b)
        if h.hexdigest() != want:
            sys.exit("md5 mismatch reading %s back from the zip" % name)
    with zipfile.ZipFile(out) as zf:
        bad = zf.testzip()
        if bad:
            sys.exit("zip test failed at " + bad)
    print("OK %s: boot %d KB @block %d, disk %d KB @block %d" % (
        out, values["BOOT_KB"], values["BOOT_SKIP"], values["DISK_KB"], values["DISK_SKIP"]))


if __name__ == "__main__":
    main()
