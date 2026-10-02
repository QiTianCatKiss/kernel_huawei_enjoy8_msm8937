#!/usr/bin/env python3
"""定位 FEATURE_WLAN_TDLS 的正确注入点。

思路：找出 prima 中被最广泛 include 的头文件，
在那里 #define FEATURE_WLAN_TDLS，可一次覆盖所有使用点。
"""
import io, os, re, sys, glob

KSRC = sys.argv[1] if len(sys.argv) > 1 else "/home/qitian/kernsrc"

# 候选：包含大量 FEATURE_ 定义的头文件
cands = []
for pat in ["drivers/prima/CORE/HDD/inc/*.h",
            "drivers/prima/CORE/SME/inc/*.h",
            "drivers/prima/CORE/VOSS/inc/*.h",
            "drivers/prima/CORE/MAC/inc/*.h"]:
    cands += glob.glob(os.path.join(KSRC, pat))

print("=== 含 FEATURE_ 宏定义的头文件（按定义数排序）===")
rows = []
for p in cands:
    try:
        with io.open(p, encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except Exception:
        continue
    defs = re.findall(r"^\s*#\s*define\s+(FEATURE_\w+|WLAN_FEATURE_\w+|WLAN_FEATURE\b)", txt, re.M)
    if defs:
        rows.append((len(defs), os.path.relpath(p, KSRC), defs[:6]))
rows.sort(reverse=True)
for n, rel, sample in rows[:8]:
    print("%4d  %s" % (n, rel))
    print("        %s" % ", ".join(sample))

# 检查 wlan_hdd_includes.h 被谁 include
inc = os.path.join(KSRC, "drivers/prima/CORE/HDD/inc/wlan_hdd_includes.h")
print()
print("=== wlan_hdd_includes.h 是否存在 ===")
print(inc if os.path.isfile(inc) else "  不存在！")

# 哪些文件 include 了 wlan_hdd_includes.h（限 prima 目录，浅层）
print()
print("=== 谁 include wlan_hdd_includes.h（drivers/prima 两层内）===")
cnt = 0
for root, dirs, files in os.walk(os.path.join(KSRC, "drivers/prima")):
    depth = root[len(KSRC):].count(os.sep)
    if depth > 6:
        dirs[:] = []
        continue
    for fn in files:
        if not fn.endswith((".c", ".h")):
            continue
        p = os.path.join(root, fn)
        try:
            with io.open(p, encoding="utf-8", errors="replace") as f:
                txt = f.read()
        except Exception:
            continue
        if "wlan_hdd_includes.h" in txt:
            cnt += 1
            if cnt <= 10:
                print("  %s" % os.path.relpath(p, KSRC))
print("  合计: %d 个文件" % cnt)