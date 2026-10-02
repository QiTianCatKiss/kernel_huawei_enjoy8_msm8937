#!/bin/bash
# 为 prima 补上缺失的 FEATURE_WLAN_TDLS 定义
#
# 背景：
#   wlan_hdd_tdls.h:37 起整份内容被 #ifdef FEATURE_WLAN_TDLS 包住
#   （含 eTDLSSupportMode:103 / tdlsConnInfo_t:257 / 函数声明 396,504,529,537）
#   wlan_hdd_main.h:1735-1743 的 scan_ctxt / tdls_mode / tdlsConnInfo 同样在内
#   wlan_hdd_cfg.h:2119 与 :3661-3662 的 TDLS 宏与成员同样在内
#   而使用点（wlan_hdd_cfg.c:2662/3652/4462、wlan_hdd_main.c:12216、
#   wlan_hdd_tdls.h:529/537）在 guard 之外
#   => 树是按「TDLS 应被定义」写的，但 FEATURE_WLAN_TDLS 全树无任何 #define
#
# 为什么注入点选 wlan_hdd_includes.h：
#   - 它被 23 个文件 include，覆盖 cfg.h / main.h 的依赖链
#   - 它自身不含任何 FEATURE_* 定义，是最上游的公共头
#   - 必须在 include guard 之前，才能对所有下游生效
#
# 幂等：靠 MARK 标记
#
# 注意：drivers/prima 与 drivers/staging/prima 是两个独立副本
#      （inode 不同，非符号链接），必须各打一次。
set -eu
KSRC=${1:-${KSRC:-$HOME/kernsrc}}
MARK="LDN-AL20-ENABLE-TDLS"

TARGETS=(
    "$KSRC/drivers/prima/CORE/HDD/inc/wlan_hdd_includes.h"
    "$KSRC/drivers/staging/prima/CORE/HDD/inc/wlan_hdd_includes.h"
)

for F in "${TARGETS[@]}"; do
    if [ ! -f "$F" ]; then
        echo "SKIP（不存在）: $F"
        continue
    fi
    if grep -q "$MARK" "$F"; then
        echo "已打补丁: $F"
        continue
    fi

    python3 - "$F" "$MARK" <<'PYEOF'
import sys, io

path, mark = sys.argv[1], sys.argv[2]
with io.open(path, encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()

lines = src.split("\n")

# 找 include guard 的起始位置（#ifndef ..._H / #ifndef __..._H 紧跟其后）
guard_at = None
for i, ln in enumerate(lines):
    s = ln.strip()
    if s.startswith("#ifndef") and s.rstrip().endswith(("H", "_H", "_H_", "_h")):
        guard_at = i
        break

if guard_at is None:
    # 无 guard，插到文件最前（版权注释之后）
    guard_at = 0
    for i, ln in enumerate(lines[:60]):
        if ln.strip().endswith("*/"):
            guard_at = i + 1
            break

ins = [
    "",
    "/* %s: 本树 wlan_hdd_tdls.h / wlan_hdd_main.h / wlan_hdd_cfg.h 的 TDLS" % mark,
    " * 内容与部分使用点均假定该宏已定义，但树中缺少其定义，导致编译失败",
    " *（eTDLSSupportMode / tdlsConnInfo_t / scan_ctxt / CFG_TDLS_* 未声明）。",
    " * 此处补上定义，使 guard 内外自洽。 */",
    "#ifndef FEATURE_WLAN_TDLS",
    "#define FEATURE_WLAN_TDLS",
    "#endif",
]

lines[guard_at:guard_at] = ins

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write("\n".join(lines))

print("patched: %s (guard@line %d)" % (path, guard_at + 1))
PYEOF
done

echo
echo "=== 校验 ==="
for F in "${TARGETS[@]}"; do
    [ -f "$F" ] || continue
    echo "--- $F"
    grep -n "$MARK\|#define FEATURE_WLAN_TDLS" "$F" | head -3
done