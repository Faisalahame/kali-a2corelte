#!/usr/bin/env python3
"""Build the TWRP zip: usage  make-zip.py OUT.zip BOOT.img ROOT.img update-binary

The root image is split into 64 MB parts (root/cNN.img), each with its own md5 in kali.manifest.
Reason: the unzip in TWRP's busybox misreads one huge entry; small parts are read reliably and a bad
part can be named in the error message.
"""
import hashlib, os, sys, zipfile

CHUNK = 64 * 1024 * 1024


def main():
    out, boot, root, ub = sys.argv[1:5]
    bsize = os.path.getsize(boot)
    rsize = os.path.getsize(root)
    bmd5 = hashlib.md5(open(boot, "rb").read()).hexdigest()
    man, rmd5 = [], hashlib.md5()
    z = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=False)
    i = 0
    with open(root, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            rmd5.update(b)
            n = "c%02d" % i
            man.append("md5 %s %s" % (n, hashlib.md5(b).hexdigest()))
            man.append("size %s %d" % (n, len(b)))
            zi = zipfile.ZipInfo("root/%s.img" % n, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            z.writestr(zi, b, compresslevel=6)
            i += 1
            print("part", n, flush=True)
    head = ["version aio-1", "boot_size %d" % bsize, "root_size %d" % rsize, "chunk_mb %d" % (CHUNK >> 20),
            "chunks %d" % i, "md5 boot %s" % bmd5, "md5 root %s" % rmd5.hexdigest()]
    z.writestr(zipfile.ZipInfo("kali.manifest", date_time=(2026, 1, 1, 0, 0, 0)), "\n".join(head + man) + "\n")
    for name, data, mode in (("META-INF/com/google/android/updater-script", b"# dummy: update-binary is a shell script\n", 0o644),
                             ("META-INF/com/google/android/update-binary", open(ub, "rb").read(), 0o755)):
        zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = mode << 16
        z.writestr(zi, data)
    zi = zipfile.ZipInfo("boot.img", date_time=(2026, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_DEFLATED
    zi.external_attr = 0o644 << 16
    z.writestr(zi, open(boot, "rb").read(), compresslevel=6)
    z.close()
    # self-check: re-read every part and compare with the manifest
    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    want = {}
    for l in z.read("kali.manifest").decode().splitlines():
        p = l.split()
        if len(p) == 3 and p[0] == "md5":
            want[p[1]] = p[2]
    for n in range(i):
        got = hashlib.md5(z.read("root/c%02d.img" % n)).hexdigest()
        assert got == want["c%02d" % n], "part c%02d does not match its md5" % n
    assert hashlib.md5(z.read("boot.img")).hexdigest() == want["boot"]
    print("OK", out, os.path.getsize(out), "bytes,", i, "parts")


if __name__ == "__main__":
    main()
