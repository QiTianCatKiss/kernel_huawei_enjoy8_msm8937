#!/bin/bash
# mkv10.sh — 构建定制内核 V10（V9 + WiFi 内核侧自启动修复）
#   内核名称 (uname -r): 3.18.66-ByQiTianCatKiss
#
# V10 相对 V9 的唯一改动（2026-10-02）：
#   在 wlan_hdd_main.c 中补回华为私有的 /proc/wifi_built_in/* 节点，
#   并增加开机 20s 自动 kickstart（失败则每 10s 重试，最多 6 次）。
#
#   背景：内置编译时 hdd_module_init() 故意 return 0，等待用户态写
#   fwpath / con_mode 才 kickstart_driver()。原厂由 wlan_detect ->
#   wifi_driver_init -> `write /proc/wifi_built_in/wifi_start start` 触发，
#   而该 proc 节点属于华为私有内核代码，公开源码树里没有，导致整条链路
#   静默失效、WiFi 永远起不来（此前只能靠 Magisk 模块 + root 写
#   /sys/module/wlan/parameters/con_mode 兜底，root 一没了就再次失效）。
#   修好后 WiFi 不再依赖 Magisk / KernelSU 模块。
set -e

KSRC=$HOME/kernsrc
OUT=$HOME/ldn-build-v10
STOCKCFG=$HOME/ldn-al20_stock_config

KVER_NAME="ByQiTianCatKiss"

rm -rf "$OUT"; mkdir -p "$OUT"

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
echo "=== 应用 WiFi 内核侧触发补丁 ==="
python3 /mnt/e/111/tools/wifi_proc_patch.py
grep -c "LDN-AL20-BUILTIN-WIFI-TRIGGER" "$KSRC/drivers/prima/CORE/HDD/src/wlan_hdd_main.c" \
  || { echo "!!!! WiFi 补丁未生效，停止构建 !!!!"; exit 1; }

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

echo "=== 应用性能优化配置 ==="

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
assert_yes DEFAULT_WESTWOOD
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

echo "=== 编译 Image.gz ==="
make O="$OUT" -j20 CONFIG_QCOM_TDLS=y CONFIG_MDNS_OFFLOAD_SUPPORT=y \
     CONFIG_PRIMA_WLAN_LFR_MBB=y CONFIG_NO_ERROR_ON_MISMATCH=y Image.gz 2>&1 | tail -30

echo "=== 结果 ==="
ls -la "$OUT/arch/arm64/boot/Image.gz"
echo "--- utsrelease ---"
cat "$OUT/include/generated/utsrelease.h"
echo "--- Linux version 字符串 ---"
strings -n 8 "$OUT/arch/arm64/boot/Image" | grep -m1 "^Linux version"
echo "--- WiFi 补丁符号是否进内核 ---"
strings -n 8 "$OUT/vmlinux" 2>/dev/null | grep -m3 "wifi_built_in" || \
  nm "$OUT/vmlinux" 2>/dev/null | grep -i "wifi_built_in" | head -5 || true

echo "=== 导出到 Windows 侧 ==="
mkdir -p /mnt/e/111/ldn-al20/out
cp "$OUT/arch/arm64/boot/Image.gz" /mnt/e/111/ldn-al20/out/Image.gz
echo "DONE. Image.gz -> /mnt/e/111/ldn-al20/out/Image.gz"
echo "Windows 侧再运行: python3 E:/111/tools/pack_kernel.py"
