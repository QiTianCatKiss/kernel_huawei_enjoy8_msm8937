#!/bin/bash
# mkv9.sh — 构建定制内核 V9（V8 性能优化 + ReSukiSU 集成）
#   内核名称 (uname -r): 3.18.66-ByQiTianCatKiss
#   在 V8 性能优化基础上，集成 ReSukiSU（内核级 root）
#
# ReSukiSU 集成要点（详见 ksu_insert.py / fix_flask.py 注释）：
#   1. setup.sh 把 KernelSU/kernel 软链为 drivers/kernelsu 并改 drivers/Makefile|Kconfig
#   2. 配置 CONFIG_KSU=y + CONFIG_KSU_MANUAL_HOOK=y（3.18 只能用 Manual Hook）
#   3. 手动插入 6 个钩子：fs/exec.c、fs/open.c、fs/stat.c x3、kernel/reboot.c
#      （setuid / initrc / input 三个钩子由 LSM / input_handler 自动完成）
#   4. Kbuild 需补 -I$(objtree)/security/selinux：flask.h 是构建期生成物，srctree 里没有
set -e

KSRC=$HOME/kernsrc
OUT=$HOME/ldn-build-v9
STOCKCFG=$HOME/ldn-al20_stock_config
#   1. I/O 调度器 cfq -> deadline  （eMMC 闪存上 CFQ 的旋转磁盘假设纯属开销，
#      deadline 保证请求期限，显著降低 I/O 延迟）
#   2. 关闭 CPU_FREQ_STAT          （每次调频都写统计，纯开销）
#   3. 关闭 SCHEDSTATS             （每次任务切换都记账，per-task 开销）
#   4. 关闭 SCHED_STACK_END_CHECK  （每次任务切换校验栈末尾）
#   5. 关闭 DEBUG_KERNEL           （调试基础设施）
#   6. 关闭 TRACING / FTRACE       （tracepoint 桩点开销）
#   7. 关闭 LOCKUP_DETECTOR / DETECT_HUNG_TASK / BOOTPARAM_SOFTLOCKUP_PANIC
#      （每 CPU 看门狗定时器 + 定期唤醒）
#   8. TCP 拥塞控制: 启用 advanced + westwood，默认 westwood
#      （westwood 在丢包的移动网络下比 cubic 更稳）
#   9. 开启 SECURITY_SELINUX_DEVELOP
#      （允许运行时 setenforce —— 这是运行时调参的前提，
#        原厂内核把它关了导致 setenforce 直接 Invalid argument）
#
# 注意：改动后统一跑 olddefconfig，Kconfig 会强制恢复被其他选项 select 的符号，
#       所以"关不掉"的项会在"最终配置校验"里如实显示。
set -e

KSRC=$HOME/kernsrc
OUT=$HOME/ldn-build-v9
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
# 注意：DEFAULT_IOSCHED 是由 choice 计算出的派生字符串（见 block/Kconfig.iosched），
#       直接改它会被 olddefconfig 按 choice 重新算回去（实测过！）。
#       必须改 choice 本身：DEFAULT_DEADLINE=y / DEFAULT_CFQ=n
#       DEFAULT_DEADLINE 可见的前提是 IOSCHED_DEADLINE=y
enable IOSCHED_DEADLINE
enable IOSCHED_NOOP
enable DEFAULT_DEADLINE
disable DEFAULT_CFQ

# --- 2~7. 移除持续运行时开销 ---
# 说明：CONFIG_DEBUG_KERNEL 关不掉 —— CONFIG_EXPERT=y 会 select 它
#       (init/Kconfig: "menuconfig EXPERT ... select DEBUG_KERNEL")。
#       DEBUG_KERNEL 本身只是调试选项的开关门，没有实质运行时开销，
#       真正要关的是它下面的具体选项，故不强求关闭它。
disable CPU_FREQ_STAT
disable SCHEDSTATS
disable SCHED_STACK_END_CHECK
# CONTEXT_SWITCH_TRACER 才是真开销：每次上下文切换都走 trace 桩点。
# 依赖链（逐层实测得出，根在 IPC_LOGGING）：
#   IPC_LOGGING -> GENERIC_TRACER -> TRACING -> EVENT_TRACING -> CONTEXT_SWITCH_TRACER
# 只关下游无效（会被上游 select 回来），必须从根 IPC_LOGGING 断掉。
# IPC_LOGGING 是高通 IPC 调试日志，关闭后相关日志调用退化为空操作。
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
# 内嵌 DWARF 调试信息，只会撑大 Image（拖慢开机解压），运行时无收益
disable DEBUG_INFO

# --- 8. TCP 拥塞控制：cubic -> westwood ---
# 同理，DEFAULT_TCP_CONG 也是 choice 派生字符串（net/ipv4/Kconfig），
# 必须改 choice：DEFAULT_WESTWOOD=y / DEFAULT_CUBIC=n
# DEFAULT_WESTWOOD 可见的前提是 TCP_CONG_ADVANCED=y 且 TCP_CONG_WESTWOOD=y
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

# --- 硬性断言：关键优化项必须真正生效，否则立即停止 ---
# （曾踩坑：直接改 DEFAULT_IOSCHED 被 olddefconfig 回滚，
#   结果编译出的内核其实没优化 —— 这里做兜底检查）
fail=0
assert_val() { # assert_val <符号> <期望值>
  local got
  got=$(grep -E "^CONFIG_$1=" "$OUT/.config" | head -1 | cut -d= -f2- | tr -d '"')
  if [ "$got" = "$2" ]; then
    echo "  [OK]   $1 = $got"
  else
    echo "  [FAIL] $1 = '$got'（期望 '$2'）"
    fail=1
  fi
}
assert_yes() { # assert_yes <符号>
  if grep -qE "^CONFIG_$1=y" "$OUT/.config"; then
    echo "  [OK]   $1 = y"
  else
    echo "  [FAIL] $1 未开启"
    fail=1
  fi
}
assert_no() { # assert_no <符号>
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
# DEBUG_KERNEL 由 EXPERT 强制 select，无法关闭，仅作提示不阻断
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
     CONFIG_PRIMA_WLAN_LFR_MBB=y CONFIG_NO_ERROR_ON_MISMATCH=y Image.gz 2>&1 | tail -12

echo "=== 结果 ==="
ls -la "$OUT/arch/arm64/boot/Image.gz"
echo "--- utsrelease ---"
cat "$OUT/include/generated/utsrelease.h"
echo "--- Linux version 字符串 ---"
strings -n 8 "$OUT/arch/arm64/boot/Image" | grep -m1 "^Linux version"

echo "=== 导出到 Windows 侧 ==="
mkdir -p /mnt/e/111/ldn-al20/out
cp "$OUT/arch/arm64/boot/Image.gz" /mnt/e/111/ldn-al20/out/Image.gz
echo "DONE. Image.gz -> /mnt/e/111/ldn-al20/out/Image.gz"
echo "Windows 侧再运行: python3 E:/111/tools/pack_kernel.py"
