# -*- coding: utf-8 -*-
"""Extract kernel Image / gzip payload / DTBs / IKCONFIG from Huawei kernel.img (Android boot image)."""
import struct, sys, os, gzip, io, zlib

SRC = r"D:/Software/dload/UPDATE_f8c83bfc/kernel.img"
OUT = r"E:/111/ldn-al20/extracted"
os.makedirs(OUT, exist_ok=True)

data = open(SRC, "rb").read()
assert data[:8] == b"ANDROID!", "not android boot image"

kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size, second_addr, tags_addr, page_size = struct.unpack_from("<8I", data, 8)
print(f"kernel_size={kernel_size} ramdisk_size={ramdisk_size} second_size={second_size} page_size={page_size}")

off = page_size
ksec = data[off:off + kernel_size]
open(os.path.join(OUT, "kernel_section.bin"), "wb").write(ksec)

# locate gzip streams
pos = 0
gz_positions = []
while True:
    i = ksec.find(b"\x1f\x8b\x08", pos)
    if i < 0:
        break
    gz_positions.append(i)
    pos = i + 1
print("gzip magic positions:", gz_positions[:20], "..." if len(gz_positions) > 20 else "")

# try decompressing each gzip candidate
for idx, i in enumerate(gz_positions):
    try:
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out = d.decompress(ksec[i:])
        end = len(ksec) - len(d.unused_data)
        open(os.path.join(OUT, f"gz_{idx}_at_{i}.bin"), "wb").write(out)
        print(f"gzip@{i}: decompressed {len(out)} bytes, stream ends at {end}")
        if out[:4] in (b"ARMd",) or out[:8] == b"ANDROID!" or len(out) > 5_000_000:
            # likely kernel Image
            open(os.path.join(OUT, "Image"), "wb").write(out)
    except Exception as e:
        print(f"gzip@{i}: failed {e}")

# locate DTB magic
pos = 0
dtbs = []
while True:
    i = ksec.find(b"\xd0\x0d\xfe\xed", pos)
    if i < 0:
        break
    dtbs.append(i)
    pos = i + 1
print(f"dtb count: {len(dtbs)}, first few: {dtbs[:10]}")
os.makedirs(os.path.join(OUT, "dtbs"), exist_ok=True)
for n, i in enumerate(dtbs):
    try:
        totalsize = struct.unpack_from(">I", ksec, i + 4)[0]
        blob = ksec[i:i + totalsize]
        open(os.path.join(OUT, "dtbs", f"dtb_{n:03d}_at_{i}.dtb"), "wb").write(blob)
    except Exception as e:
        print(f"dtb@{i}: failed {e}")

# IKCONFIG
ik = ksec.find(b"IKCFG_ST")
print("IKCFG_ST at:", ik)
if ik >= 0:
    g = ik + 8
    try:
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        cfg = d.decompress(ksec[g:])
        open(os.path.join(OUT, "kernel_config.txt"), "wb").write(cfg)
        print(f"config extracted: {len(cfg)} bytes")
    except Exception as e:
        print("ikconfig decompress failed:", e)

# kernel version string
vs = ksec.find(b"Linux version ")
if vs >= 0:
    end = ksec.find(b"\x00", vs)
    print("version:", ksec[vs:end].decode(errors="replace"))
