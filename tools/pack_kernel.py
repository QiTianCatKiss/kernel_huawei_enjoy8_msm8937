# -*- coding: utf-8 -*-
"""按原厂格式打包 LDN-AL20 kernel.img:
[2048B Android boot 头(复用原厂, 仅改 kernel_size)] + [Image.gz] + [163 个 QCDT DTB] + [原厂签名尾块]
"""
import struct, glob, os, re, sys

STOCK = r"D:/Software/dload/UPDATE_f8c83bfc/kernel.img"
GZ = r"E:/111/ldn-al20/out/Image.gz"
DTB_DIR = r"E:/111/ldn-al20/extracted/dtbs"
OUT = r"E:/111/ldn-al20/out/kernel.img"
EXTRA_CMDLINE = sys.argv[1] if len(sys.argv) > 1 else ""

stock = open(STOCK, "rb").read()
stock_ks = struct.unpack_from("<I", stock, 8)[0]
header = bytearray(stock[:2048])          # 原厂头部(含 cmdline/name/id)
tail = stock[2048 + stock_ks:]            # 原厂签名尾块

if EXTRA_CMDLINE:
    cmd = stock[66:594].split(b"\x00")[0] + b" " + EXTRA_CMDLINE.encode()
    assert len(cmd) < 512, "cmdline overflow"
    header[66:594] = cmd + b"\x00" * (512 - len(cmd))
    print("附加 cmdline:", EXTRA_CMDLINE)

gz = open(GZ, "rb").read()

# 按原厂偏移顺序拼接 DTB
dtbs = []
for f in glob.glob(os.path.join(DTB_DIR, "dtb_*.dtb")):
    m = re.search(r"_at_(\d+)\.dtb$", f)
    dtbs.append((int(m.group(1)), f))
dtbs.sort()
blob = b"".join(open(f, "rb").read() for _, f in dtbs)
print(f"DTB 数量: {len(dtbs)}, 总大小: {len(blob)} (原厂: {stock_ks - 12560493})")

kernel_size = len(gz) + len(blob)
struct.pack_into("<I", header, 8, kernel_size)

with open(OUT, "wb") as fo:
    fo.write(header)
    fo.write(gz)
    fo.write(blob)
    fo.write(tail)

print(f"kernel_size={kernel_size} (原厂 {stock_ks})")
print(f"输出: {OUT}, 大小: {2048 + kernel_size + len(tail)}")
