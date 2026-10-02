#!/bin/bash
# ksu_pin.sh — 把 ReSukiSU 源码钉到 v4.2.0-rc3 tag
#
# 为什么要钉版本：
#   KernelSU 内核侧版本号是算出来的 —— Kbuild:
#     KSU_LOCAL_VERSION := $(shell git rev-list --count HEAD)
#     KSU_VERSION       := 30000 + KSU_LOCAL_VERSION + 700
#   如果 clone 的是 main 分支 HEAD（4495 commits）→ KSU_VERSION=35195，
#   而官方已发布的管理器最新只到 v4.2.0-rc3 = 35171。
#   管理器发现"内核比我还新"会直接拒绝工作：
#     装不上 /data/adb/ksud、给不了任何应用授权 → su 完全调不出来。
#   切到 v4.2.0-rc3（4471 commits）→ KSU_VERSION=35171，与官方管理器精确配对。
#
# 用法：
#   bash ksu_pin.sh [内核源码树根目录]   # 默认 $KSRC 或 ~/kernsrc
set -e

KSRC=${1:-${KSRC:-$HOME/kernsrc}}
KSU=$KSRC/KernelSU
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$KSU"

echo "=== 切换前 ==="
echo "HEAD        : $(git rev-list --count HEAD) commits"
echo "KSU_VERSION : $((30000 + $(git rev-list --count HEAD) + 700))"
echo "describe    : $(git describe --abbrev=0 --tags 2>/dev/null || echo none)"
echo "工作区改动  :"
git status --porcelain || true

echo
echo "=== 切到 v4.2.0-rc3（-f 丢弃本地 Kbuild 改动，稍后重打）==="
git checkout -f v4.2.0-rc3

echo
echo "=== 切换后 ==="
CNT=$(git rev-list --count HEAD)
echo "HEAD        : $CNT commits ($(git rev-parse --short=8 HEAD))"
echo "KSU_VERSION : $((30000 + CNT + 700))"
echo "describe    : $(git describe --abbrev=0 --tags 2>/dev/null || echo none)"
echo "工作区改动  :"
git status --porcelain || true

echo
echo "=== 重新打 flask.h 补丁（3.18 必需）==="
python3 "$HERE/fix_flask.py"

echo
echo "=== 校验 symlink 与 Kbuild ==="
ls -la "$KSRC/drivers/kernelsu"
grep -n "objtree)/security/selinux" "$KSU/kernel/Kbuild"
grep -c "KSU_VERSION" "$KSU/kernel/Kbuild"

echo
echo "=== 校验 manual hook 仍在（属主内核源码，不受切 tag 影响）==="
echo -n "fs/exec.c       ksu_handle_execveat : "; grep -c "ksu_handle_execveat" "$KSRC/fs/exec.c" || true
echo -n "fs/open.c       ksu_handle_faccessat: "; grep -c "ksu_handle_faccessat" "$KSRC/fs/open.c" || true
echo -n "fs/stat.c       ksu_handle_stat     : "; grep -c "ksu_handle_stat\|ksu_handle_newfstat_ret\|ksu_handle_fstat64_ret" "$KSRC/fs/stat.c" || true
echo -n "kernel/reboot.c ksu_handle_reboot   : "; grep -c "ksu_handle_sys_reboot" "$KSRC/kernel/reboot.c" || true
echo -n "wlan_hdd_main.c WiFi 补丁标记       : "; grep -c "LDN-AL20-BUILTIN-WIFI-TRIGGER" "$KSRC/drivers/prima/CORE/HDD/src/wlan_hdd_main.c" || true
