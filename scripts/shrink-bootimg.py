#!/usr/bin/env python3
"""Shrink an Android boot.img so it fits a small BOOT partition.

The postmarketOS kernel is a raw arm64 Image (~31 MB). The Galaxy A2 Core BOOT partition is
only 32 MiB, so boot.img (kernel + ~10 MB initramfs) does not fit. This tool rewrites the
image with a gzip-compressed kernel (Image.gz), which is about a third of the size.
Everything else (ramdisk, dtb/second, cmdline, offsets, page size) is copied unchanged.

usage: shrink-bootimg.py boot.img LIMIT_BYTES
"""
import gzip
import hashlib
import struct
import sys

path, limit = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read()
print(f"boot.img: {len(data)} bytes, limit {limit} bytes")

if data[:8] != b"ANDROID!":
    sys.exit("ERROR: not an Android boot image")

(ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page, hv_dt, osver) = struct.unpack_from("<10I", data, 8)
print(f"page_size={page} kernel={ksize} ramdisk={rsize} second={ssize} header_version/dt_size={hv_dt}")

def pad(n):
    return (n + page - 1) // page * page

kernel = data[page:page + ksize]
roff = page + pad(ksize)
ramdisk = data[roff:roff + rsize]
rest = data[roff + pad(rsize):]  # second stage / dt / dtbo etc, copied verbatim

if len(data) <= limit:
    print("already fits, nothing to do")
    sys.exit(0)

if kernel[:2] == b"\x1f\x8b":
    sys.exit("ERROR: the kernel is already gzip-compressed and the image is still too big. "
             "The BOOT partition has to be enlarged (or a smaller kernel used).")
print("kernel magic at 0x38:", kernel[0x38:0x3c], "(b'ARM\\x64' = raw arm64 Image)")

gz = gzip.compress(kernel, 9, mtime=0)
print(f"kernel {len(kernel)} -> gzip {len(gz)} bytes")

hdr = bytearray(data[:page])
struct.pack_into("<I", hdr, 8, len(gz))
# header id = sha1 over the sections, like mkbootimg does (the bootloader does not check it)
sha = hashlib.sha1()
sha.update(gz); sha.update(struct.pack("<I", len(gz)))
sha.update(ramdisk); sha.update(struct.pack("<I", rsize))
second = rest[:ssize]
sha.update(second); sha.update(struct.pack("<I", ssize))
if hv_dt > 2:  # old-style header: this field is the size of a dt image
    sha.update(rest[pad(ssize):pad(ssize) + hv_dt]); sha.update(struct.pack("<I", hv_dt))
hdr[576:608] = sha.digest() + b"\x00" * (32 - sha.digest_size)

def padded(b):
    return b + b"\x00" * (pad(len(b)) - len(b))

out = bytes(hdr) + padded(gz) + padded(ramdisk) + rest
open(path, "wb").write(out)
print(f"new boot.img: {len(out)} bytes ({'fits' if len(out) <= limit else 'STILL TOO BIG'})")
if len(out) > limit:
    sys.exit(1)
