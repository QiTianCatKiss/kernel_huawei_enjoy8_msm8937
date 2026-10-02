#!/bin/bash
# V12-debug 内核构建：完整流程
#  与 V11 的差异：显式重开 ftrace / kprobes / hung-task / debug-info / sysrq
#  保留 V11 的全部 WiFi 修复与 ReSukiSU 钩子，便于对照。
set -u
KSRC=${KSRC:-$HOME/kernsrc}
OUT=${OUT:-$HOME/ldn-build-v12dbg}
JOBS=${JOBS:-20}
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-
TOOLS=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-/mnt/e/111/ldn-al20}

step() { echo; echo "########## $* ##########"; }

# --- config 操作原语（沿用 mkv11.sh 的三种形态处理）---
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
setval() {
  sed -i "/^# CONFIG_$1 is not set$/d" "$OUT/.config"
  if grep -q "^CONFIG_$1=" "$OUT/.config"; then
    sed -i "s|^CONFIG_$1=.*|CONFIG_$1=$2|" "$OUT/.config"
  else
    echo "CONFIG_$1=$2" >> "$OUT/.config"
  fi
}

step "1/10 KSU 钉版"
bash "$TOOLS/ksu_pin.sh" "$KSRC"

step "2/10 WiFi 内核侧自启动修复"
S="$KSRC/fs/overlayfs/super.c"
if grep -q 'prctl(PR_SET_MM, PR_SET_MM_MAP, 0)' "$S" 2>/dev/null; then
    echo "PRETS 补丁存在，跳过"
else
    echo "!! /prets 未打补丁"
fi
python3 "$TOOLS/wifi_proc_patch.py" "$KSRC"
echo "WiFi 触发点: $(grep -c 'LDN-AL20-BUILTIN-WIFI-TRIGGER' "$KSRC/drivers/prima/CORE/HDD/src/wlan_hdd_main.c")"

step "3/10 KSU execve 钩子"
python3 "$TOOLS/ksu_exec_hook_fix.py" "$KSRC"
echo "execve 钩子标记: $(grep -c 'KSU_EXEC_HOOK_V2' "$KSRC/fs/exec.c")"

step "4/10 prima TDLS 宏补丁（补 FEATURE_WLAN_TDLS，两版构建都必需）"
bash "$TOOLS/prima_tdls_fix.sh" "$KSRC"
if ! grep -q "LDN-AL20-ENABLE-TDLS" "$KSRC/drivers/prima/CORE/HDD/inc/wlan_hdd_includes.h"; then
    echo ">>> prima TDLS 补丁未生效，终止"
    exit 1
fi

step "5/10 Kconfig 补丁（arm64 select HAVE_REGS_AND_STACK_ACCESS_API）"
bash "$TOOLS/v12dbg_kconfig_patch.sh" "$KSRC"

step "6/10 准备 config 基线"
mkdir -p "$OUT"
if [ -f "$HOME/ldn-build-v10/.config" ]; then
    cp "$HOME/ldn-build-v10/.config" "$OUT/.config"
    echo "基线取自 ldn-build-v10"
else
    (cd "$KSRC" && make O="$OUT" msm8937_defconfig >/dev/null 2>&1)
    echo "基线取自 msm8937_defconfig"
fi

step "7/10 沿用 V11 的 WiFi / 安全 / ReSukiSU 配置"
for k in PRIMA_WLAN_LFR PRIMA_WLAN_OKC PRIMA_WLAN_11AC_HIGH_TP NL80211_TESTMODE \
         IOSCHED_DEADLINE IOSCHED_NOOP DEFAULT_DEADLINE \
         TCP_CONG_ADVANCED TCP_CONG_WESTWOOD DEFAULT_WESTWOOD \
         SECURITY_SELINUX_DEVELOP SECURITY_SELINUX_BOOTPARAM \
         HUAWEI_PATCH_OVERLAY KSU KSU_MANUAL_HOOK; do
    enable "$k"
done
disable DEFAULT_CFQ
disable HUAWEI_CFI
disable MODULE_SIG
disable MODULE_SIG_ALL
disable MODULE_SIG_FORCE

step "8/10 === V12 核心：重开全部调试能力 ==="
# --- 总闸门（KPROBES/KRETPROBES 的硬依赖）---
enable HUAWEI_KERNEL_DEBUG
# --- kprobes 体系 ---
enable KPROBES
enable KRETPROBES
enable KPROBE_EVENT
disable OPTPROBES
# --- ftrace 体系 ---
enable TRACING_SUPPORT
enable FTRACE
enable FUNCTION_TRACER
enable FUNCTION_GRAPH_TRACER
enable DYNAMIC_FTRACE
enable HAVE_DYNAMIC_FTRACE_WITH_REGS
enable FTRACE_SYSCALLS
enable CONTEXT_SWITCH_TRACER
enable NOP_TRACER
enable RING_BUFFER
enable GENERIC_TRACER
enable TRACING
enable STACKTRACER
enable SCHED_TRACER
enable ENABLE_DEFAULT_TRACERS
enable FTRACE_SELFTEST
enable FTRACE_MCOUNT_RECORD
disable IRQSOFF_TRACER
disable PREEMPT_TRACER
disable TRACER_SNAPSHOT
# --- 卡死检测 / 栈回溯 ---
enable DEBUG_KERNEL
enable DETECT_HUNG_TASK
setval DEFAULT_HUNG_TASK_TIMEOUT 140
enable BOOTPARAM_HUNG_TASK_PANIC
enable PANIC_ON_OOPS
enable LOCKUP_DETECTOR
enable SOFTLOCKUP_DETECTOR
enable HARDLOCKUP_DETECTOR
setval DEFAULT_LOCKUP_TIMEOUT 20
enable SCHEDSTATS
enable DEBUG_INFO
enable DEBUG_INFO_DWARF
enable MAGIC_SYSRQ
setval MAGIC_SYSRQ_DEFAULT_ENABLE 0x1
# --- 压回高开销项（保留调试能力，去掉纯性能损耗）---
disable DEBUG_VMALLOC
disable DEBUG_PAGEALLOC
disable DEBUG_MUTEXES
disable DEBUG_SPINLOCK
disable DEBUG_LIST
disable FAULT_INJECTION
disable FREE_PAGES_RDONLY
disable DEVMEM
disable MSM_RTB
disable MSM_RTB_SEPARATE_CPUS
disable IPC_LOGGING
disable WIL6210_TRACING
disable SCHED_STACK_END_CHECK
# --- 确认不可用项 ---
disable UPROBES
disable BPF_SYSCALL

step "9/10 olddefconfig + 断言"
cd "$KSRC" || exit 1
make O="$OUT" olddefconfig >/dev/null 2>&1

ASSERT_FAIL=0
must_on="HUAWEI_KERNEL_DEBUG KPROBES KRETPROBES KPROBE_EVENT FTRACE FUNCTION_TRACER
         DYNAMIC_FTRACE FTRACE_SYSCALLS TRACING TRACING_SUPPORT RING_BUFFER
         GENERIC_TRACER DETECT_HUNG_TASK LOCKUP_DETECTOR DEBUG_INFO
         MAGIC_SYSRQ KSU KSU_MANUAL_HOOK SECURITY_SELINUX_DEVELOP
         HUAWEI_PATCH_OVERLAY DEFAULT_WESTWOOD"
echo "--- 必须为 y ---"
for k in $must_on; do
    if grep -qE "^CONFIG_${k}=y" "$OUT/.config"; then
        printf "  OK   %s\n" "$k"
    else
        printf "  FAIL %s -> %s\n" "$k" "$(grep -E "^CONFIG_${k}=|^# CONFIG_${k} is not set" "$OUT/.config" | head -1)"
        ASSERT_FAIL=$((ASSERT_FAIL+1))
    fi
done
echo "--- 必须为 n（高开销项）---"
for k in DEBUG_VMALLOC DEBUG_PAGEALLOC DEBUG_MUTEXES DEBUG_SPINLOCK UPROBES BPF_SYSCALL DEFAULT_CFQ; do
    if grep -qE "^# CONFIG_${k} is not set" "$OUT/.config"; then
        printf "  OK   %s=n\n" "$k"
    else
        printf "  FAIL %s 未关闭 -> %s\n" "$k" "$(grep -E "^CONFIG_${k}=" "$OUT/.config" | head -1)"
        ASSERT_FAIL=$((ASSERT_FAIL+1))
    fi
done
echo "断言失败数: $ASSERT_FAIL"
[ "$ASSERT_FAIL" -ne 0 ] && { echo ">>> 配置断言未通过，终止编译"; exit 1; }

step "10/10 编译 + objdump 断言"
export KBUILD_BUILD_USER=android KBUILD_BUILD_HOST=localhost
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="$(date '+%a %b %d %H:%M:%S %Z %Y')"

make O="$OUT" -j"$JOBS" > /tmp/v12dbg_make.log 2>&1
RC=$?
tail -25 /tmp/v12dbg_make.log
echo "make 退出码: $RC"
if [ "$RC" -ne 0 ]; then
    echo ">>> 编译失败，日志：/tmp/v12dbg_make.log"
    echo "--- 首个 error 行 ---"
    grep -m 20 -E "error:|Error [0-9]|No rule to make" /tmp/v12dbg_make.log
    exit 1
fi

OBJDUMP=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-objdump
if [ -f "$OUT/fs/exec.o" ] && [ -x "$OBJDUMP" ]; then
    CNT=$("$OBJDUMP" -r "$OUT/fs/exec.o" | grep -c "R_AARCH64_CALL26.*ksu_handle_")
    echo "fs/exec.o 中 ksu_handle_* 重定位: $CNT"
    [ "$CNT" -ge 3 ] || { echo ">>> KSU 钩子断言失败"; exit 1; }
fi
if [ -f "$OUT/vmlinux" ] && [ -x "$OBJDUMP" ]; then
    echo "--- vmlinux 调试符号抽查 ---"
    for sym in register_kprobe __stack_trace task_stack_trace; do
        if "$OBJDUMP" -t "$OUT/vmlinux" | grep -q "\b$sym\b"; then
            echo "  OK   $sym"
        else
            echo "  MISS $sym"
        fi
    done
fi

step "导出"
mkdir -p "$REPO/out"
[ -f "$OUT/arch/arm64/boot/Image" ] && cp "$OUT/arch/arm64/boot/Image" "$REPO/out/kernel-v12dbg"
DTB=$(ls "$OUT"/arch/arm64/boot/dts/msm/msm8937*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] && [ -f "$DTB" ] && cp "$DTB" "$REPO/out/"
[ -f "$OUT/System.map" ] && cp "$OUT/System.map" "$REPO/out/System.map-v12dbg"
[ -f "$OUT/vmlinux" ] && cp "$OUT/vmlinux" "$REPO/out/vmlinux-v12dbg"
[ -f "$OUT/.config" ] && cp "$OUT/.config" "$REPO/out/config-v12dbg"
ls -l "$REPO/out/"*v12dbg* 2>/dev/null
echo "=== 完成 ==="