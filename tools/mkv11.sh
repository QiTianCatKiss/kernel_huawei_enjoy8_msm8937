#!/bin/bash
# mkv11.sh — 构建定制内核 V11（V10 + ReSukiSU su 修复）
#   内核名称 (uname -r): 3.18.66-ByQiTianCatKiss
#
# V11 相对 V10 的改动（2026-10-02）：
#   1) KernelSU 源码钉到 v4.2.0-rc3 tag（KSU_VERSION 35171，与官方管理器配对）
#   2) 修复 fs/exec.c 的 manual hook 接线错误 —— su 永远不可用的根因
#
# 【1】为什么要钉版本
#   KernelSU 内核侧版本号是算出来的（KernelSU/kernel/Kbuild）：
#       KSU_LOCAL_VERSION := $(shell git rev-list --count HEAD)
#       KSU_VERSION       := 30000 + KSU_LOCAL_VERSION + 700
#   clone main 分支 HEAD = 4495 commits → 35195，比官方管理器（35171）还新，
#   管理器会直接拒绝工作：装不上 /data/adb/ksud、给不了应用授权 → su 调不出来。
#   v4.2.0-rc3 = 4471 commits → 35171，精确配对。
#
# 【2】exec hook 根因
#   fs/exec.c 的 do_execve_common() 当初只挂了 ksu_handle_execveat_ksud()，
#   而 sucompat（把 /system/bin/su 重定向到 /data/adb/ksud 的全部逻辑）挂在
#   ksu_handle_execve() 内部，从来没被调用过。
#   没被 build 发现的���因：KernelSU 的 tools/manual_hook_check.mk 用
#       grep -q "ksu_handle_execveat" fs/exec.c
#   做检查，而我们插入的 ksu_handle_execveat_ksud 正好是它的子串 → 误判通过。
#
#   3.18 没有 execveat 系统调用，execve / compat_execve 都汇聚到
#   do_execve_common()，所以那里是唯一且正确的挂载点。
#
# 产物：out/Image.gz → Windows 侧 pack_kernel.py → out/kernel.img
set -e

KSRC=${KSRC:-$HOME/kernsrc}
OUT=$HOME/ldn-build-v11
STOCKCFG=${STOCKCFG:-$HOME/ldn-al20_stock_config}
TOOLS=$(cd "$(dirname "$0")" && pwd)
# 产物导出目录（Windows 侧仓库的 out/）
REPO=${REPO:-/mnt/e/111/ldn-al20}
OUTDIR=$REPO/out

KVER_NAME="ByQiTianCatKiss"

rm -rf "$OUT"; mkdir -p "$OUT"

# --- [0] KernelSU 钉版 + flask.h 补丁（必须在 Kbuild 读版本号之前）---
echo "=== [0/6] ReSukiSU 钉到 v4.2.0-rc3 ==="
bash "$TOOLS/ksu_pin.sh" "$KSRC"

# --- apply overlay /prets fix (idempotent) ---
SUPER="$KSRC/fs/overlayfs/super.c"
if ! grep -q '"/prets/"' "$SUPER"; then
  python3 - "$SUPER" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
old='        if(0 == strncmp(ufs->config.workdir, PATCH_HW_PATH_NAME, strlen(PATCH_HW_PATH_NAME))){'
new='        if(0 == strncmp(ufs->config.workdir, PATCH_HW_PATH_NAME, strlen(PATCH_HW_PATH_NAME))\n           || 0 == strncmp(ufs->config.workdir, "/prets/", strlen("/prets/"))){'
assert old in s, "ANCHOR NOT FOUND"
s=s.replace(old,new,1)
open(p,'w').write(s)
print("[*] patched super.c for /prets")
PY
else
  echo "[*] /prets guard already present"
fi

# --- apply built-in WLAN stock-trigger emulation (idempotent) ---
echo "=== [1/7] 应用 WiFi 内核侧触发补丁 ==="
python3 "$TOOLS/wifi_proc_patch.py" "$KSRC"
grep -c "LDN-AL20-BUILTIN-WIFI-TRIGGER" "$KSRC/drivers/prima/CORE/HDD/src/wlan_hdd_main.c" \
  || { echo "!!!! WiFi 补丁未生效，停止构建 !!!!"; exit 1; }

# --- define missing FEATURE_WLAN_TDLS (idempotent) ---
# 该宏在树中无任何 #define，而 prima 大量代码假定它已定义：
#   wlan_hdd_tdls.h:37 起整份内容、wlan_hdd_main.h:1735-1743 的 scan_ctxt、
#   wlan_hdd_cfg.h:2119 与 :3661-3662 的 TDLS 宏均被 #ifdef 包住
# 不补则编译报 15 个 CFG_TDLS_* / CFG_ENABLE_*_BMISS 宏未声明错误。
echo "=== [2/7] 补 prima TDLS 宏定义 ==="
bash "$TOOLS/prima_tdls_fix.sh" "$KSRC"
grep -q "LDN-AL20-ENABLE-TDLS" "$KSRC/drivers/prima/CORE/HDD/inc/wlan_hdd_includes.h" \
  || { echo "!!!! prima TDLS 补丁未生效，停止构建 !!!!"; exit 1; }

# --- fix KSU execve hook wiring (idempotent) ---
echo "=== [3/7] 应用 KSU execve 钩子修复 ==="
python3 "$TOOLS/ksu_exec_hook_fix.py" "$KSRC"
grep -c "KSU_EXEC_HOOK_V2" "$KSRC/fs/exec.c" \
  || { echo "!!!! execve 钩子补丁未生效，停止构建 !!!!"; exit 1; }

cp "$STOCKCFG" "$OUT/.config"

# --- 内核名称 ---
sed -i "s/^CONFIG_LOCALVERSION=\"\"/CONFIG_LOCALVERSION=\"-$KVER_NAME\"/" "$OUT/.config"
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT/.config"

# --- WLAN 特性（prima 编译需要）---
for k in WLAN_FEATURE_11W QCOM_VOWIFI_11R ENABLE_LINUX_REG WLAN_OFFLOAD_PACKETS \
         PRIMA_WLAN_LFR PRIMA_WLAN_OKC PRIMA_WLAN_11AC_HIGH_TP NL80211_TESTMODE; do
  sed -i "s/^# CONFIG_$k is not set/CONFIG_$k=y/" "$OUT/.config"
done
sed -i 's/^CONFIG_HUAWEI_CFI=y/# CONFIG_HUAWEI_CFI is not set/' "$OUT/.config"
sed -i 's/^# CONFIG_HUAWEI_PATCH_OVERLAY is not set/CONFIG_HUAWEI_PATCH_OVERLAY=y/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG_ALL=y/# CONFIG_MODULE_SIG_ALL is not set/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG_FORCE=y/# CONFIG_MODULE_SIG_FORCE is not set/' "$OUT/.config"

# enable <符号>：把符号置为内建 y。
#   三种形态都要处理：
#     "# CONFIG_X is not set"  -> "CONFIG_X=y"
#     "CONFIG_X=m"（模块）      -> "CONFIG_X=y"（choice 只认 =y）
#     完全不存在                -> 追加一行（stock config 里常没有该行！）
disable() { sed -i "s/^CONFIG_$1=y/# CONFIG_$1 is not set/;s/^CONFIG_$1=m/# CONFIG_$1 is not set/" "$OUT/.config"; }
enable() {
  if grep -qE "^# CONFIG_$1 is not set" "$OUT/.config"; then
    sed -i "s/^# CONFIG_$1 is not set/CONFIG_$1=y/" "$OUT/.config"
  elif grep -qE "^CONFIG_$1=[mn]" "$OUT/.config"; then
    sed -i "s/^CONFIG_$1=[mn]/CONFIG_$1=y/" "$OUT/.config"
  elif ! grep -qE "^CONFIG_$1=y" "$OUT/.config"; then
    echo "CONFIG_$1=y" >> "$OUT/.config"
  fi
}

echo "=== [4/7] 应用性能优化配置 ==="

# --- 1. I/O 调度器：cfq -> deadline ---
enable IOSCHED_DEADLINE
enable IOSCHED_NOOP
enable DEFAULT_DEADLINE
disable DEFAULT_CFQ

# --- 2~7. 移除持续运行时开销 ---
disable CPU_FREQ_STAT
disable SCHEDSTATS
disable SCHED_STACK_END_CHECK
disable IPC_LOGGING
disable WIL6210_TRACING
disable EVENT_TRACING
disable SCHED_TRACER
disable CONTEXT_SWITCH_TRACER
disable FUNCTION_TRACER
disable TRACING
disable FTRACE
disable LOCKUP_DETECTOR
disable SOFTLOCKUP_DETECTOR
disable HARDLOCKUP_DETECTOR
disable DETECT_HUNG_TASK
disable BOOTPARAM_SOFTLOCKUP_PANIC
disable DEBUG_INFO

# --- 8. TCP 拥塞控制：cubic -> westwood ---
enable TCP_CONG_ADVANCED
enable TCP_CONG_WESTWOOD
enable DEFAULT_WESTWOOD
disable DEFAULT_CUBIC

# --- 9. 允许运行时 setenforce（运行时调参的前提）---
enable SECURITY_SELINUX_DEVELOP
enable SECURITY_SELINUX_BOOTPARAM

# --- 10. ReSukiSU（Manual Hook 模式，3.18 只能用它）---
enable KSU
enable KSU_MANUAL_HOOK

export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-
export KBUILD_BUILD_USER=android
export KBUILD_BUILD_HOST=localhost
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="$(date '+%a %b %d %H:%M:%S %Z %Y')"

cd "$KSRC"
make O="$OUT" olddefconfig >/dev/null 2>&1

echo "=== 最终配置校验（olddefconfig 之后的实际值）==="
grep -E '^(CONFIG_LOCALVERSION=|CONFIG_LOCALVERSION_AUTO|CONFIG_HZ=|CONFIG_DEFAULT_IOSCHED=|CONFIG_IOSCHED_|CONFIG_CPU_FREQ_STAT=|CONFIG_SCHEDSTATS=|CONFIG_SCHED_STACK_END_CHECK=|CONFIG_DEBUG_KERNEL=|CONFIG_TRACING=|CONFIG_FTRACE=|CONFIG_LOCKUP_DETECTOR=|CONFIG_DETECT_HUNG_TASK=|CONFIG_DEFAULT_TCP_CONG=|CONFIG_TCP_CONG_WESTWOOD=|CONFIG_SECURITY_SELINUX_DEVELOP=|CONFIG_SECURITY_SELINUX_BOOTPARAM=|CONFIG_HUAWEI_CFI=|CONFIG_HUAWEI_PATCH_OVERLAY=)' "$OUT/.config"
grep -E '^CONFIG_(DEFAULT_DEADLINE|DEFAULT_CFQ|DEFAULT_WESTWOOD|DEFAULT_CUBIC)=|^# CONFIG_(DEFAULT_DEADLINE|DEFAULT_CFQ|DEFAULT_WESTWOOD|DEFAULT_CUBIC) is not set' "$OUT/.config"
echo "KBUILD_BUILD_TIMESTAMP = $KBUILD_BUILD_TIMESTAMP"

# --- 硬性断言 ---
fail=0
assert_val() {
  local got
  got=$(grep -E "^CONFIG_$1=" "$OUT/.config" | head -1 | cut -d= -f2- | tr -d '"')
  if [ "$got" = "$2" ]; then
    echo "  [OK]   $1 = $got"
  else
    echo "  [FAIL] $1 = '$got'（期望 '$2'）"
    fail=1
  fi
}
assert_yes() {
  if grep -qE "^CONFIG_$1=y" "$OUT/.config"; then
    echo "  [OK]   $1 = y"
  else
    echo "  [FAIL] $1 未开启"
    fail=1
  fi
}
assert_no() {
  if grep -qE "^# CONFIG_$1 is not set" "$OUT/.config" || ! grep -qE "^CONFIG_$1=[ym]" "$OUT/.config"; then
    echo "  [OK]   $1 已关闭"
  else
    echo "  [FAIL] $1 仍在开启"
    fail=1
  fi
}
echo "=== 关键优化项断言 ==="
assert_val DEFAULT_IOSCHED deadline
assert_yes DEFAULT_DEADLINE
assert_val DEFAULT_TCP_CONG westwood
assert_yes WESTWOOD
assert_yes SECURITY_SELINUX_DEVELOP
assert_yes KSU
assert_yes KSU_MANUAL_HOOK
assert_no  SCHEDSTATS
assert_no  CPU_FREQ_STAT
assert_no  CONTEXT_SWITCH_TRACER
assert_no  LOCKUP_DETECTOR
assert_no  DEBUG_INFO
if grep -qE "^CONFIG_DEBUG_KERNEL=y" "$OUT/.config"; then
  echo "  [提示] DEBUG_KERNEL 仍开启（被 CONFIG_EXPERT 强制 select，无实质开销）"
fi
if [ "$fail" -ne 0 ]; then
  echo "!!!! 关键优化项未生效，停止构建（避免产出未优化的内核） !!!!"
  exit 1
fi
echo "== 全部通过 =="

echo "=== [5/7] 编译 Image.gz ==="
make O="$OUT" -j20 CONFIG_QCOM_TDLS=y CONFIG_MDNS_OFFLOAD_SUPPORT=y \
     CONFIG_PRIMA_WLAN_LFR_MBB=y CONFIG_NO_ERROR_ON_MISMATCH=y Image.gz 2>&1 | tail -30

echo "=== [6/7] 对象级验证：fs/exec.o 必须有 3 个 KSU 重定位 ==="
OBJDUMP=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-objdump
if [ -x "$OBJDUMP" ]; then
  "$OBJDUMP" -dr "$OUT/fs/exec.o" 2>/dev/null \
    | grep -E "R_AARCH64_CALL26\s+ksu_handle_(execve|execveat_ksud|post_execve)" \
    | sed 's/^/  /' || true
  N=$("$OBJDUMP" -dr "$OUT/fs/exec.o" 2>/dev/null \
      | grep -cE "R_AARCH64_CALL26\s+ksu_handle_(execve|execveat_ksud|post_execve)" || true)
  if [ "${N:-0}" -ge 3 ]; then
    echo "  [OK]   fs/exec.o 含 $N 个 KSU 钩子调用"
  else
    echo "  [FAIL] fs/exec.o 只有 ${N:-0} 个 KSU 钩子调用（期望 >= 3）"
    exit 1
  fi
else
  echo "  [跳过] 找不到 $OBJDUMP"
fi

echo "=== [7/7] 结果 ==="
ls -la "$OUT/arch/arm64/boot/Image.gz"
echo "--- utsrelease ---"
cat "$OUT/include/generated/utsrelease.h"
echo "--- Linux version 字符串 ---"
strings -n 8 "$OUT/arch/arm64/boot/Image" | grep -m1 "^Linux version"
echo "--- KSU 版本（必须 35171）---"
grep -m1 "Linux version" "$OUT/include/generated/compile.h" 2>/dev/null || true
strings -n 8 "$OUT/vmlinux" 2>/dev/null | grep -m3 "wifi_built_in" || \
  nm "$OUT/vmlinux" 2>/dev/null | grep -i "wifi_built_in" | head -5 || true

echo "=== 导出符号表（供离线符号化 panic/oops）==="
mkdir -p "$OUTDIR/symbols"
cp "$OUT/System.map" "$OUTDIR/symbols/System.map-v11" 2>/dev/null || true
cp "$OUT/vmlinux"   "$OUTDIR/symbols/vmlinux-v11"   2>/dev/null || true
ls -la "$OUTDIR/symbols/" 2>/dev/null || true

echo "=== 导出到 Windows 侧 ==="
mkdir -p "$OUTDIR"
cp "$OUT/arch/arm64/boot/Image.gz" "$OUTDIR/Image.gz"
cp "$OUT/arch/arm64/boot/Image"    "$OUTDIR/Image"
echo "DONE. Image.gz -> $OUTDIR/Image.gz"
echo "Windows 侧再运行: python tools/pack_kernel.py  # -> out/kernel.img"
echo "刷入: fastboot flash kernel out/kernel.img && fastboot reboot"
