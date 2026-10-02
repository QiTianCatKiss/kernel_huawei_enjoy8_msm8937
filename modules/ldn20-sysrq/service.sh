#!/system/bin/sh
# ldn20-sysrq —— service（开机后复检 + handler 注册确认）
#
# post-fs-data 阶段开启后，这里再确认一次：
#   1. sysrq_enabled 是否仍为开启（华为 init.rc 可能在 late_start 改写）
#   2. sysrq input handler 是否真的注册（决定组合键是否可用）

SYSCTL=/proc/sys/kernel/sysrq
TRIGGER=/proc/sysrq-trigger
OUT=/data/local/tmp/sysrq_status.txt

sleep 60

{
    echo
    echo "=== 开机 60s 后复检 ==="
    V=$(cat "$SYSCTL" 2>/dev/null)
    echo "sysrq_enabled = ${V:-<读取失败>}"

    if [ "$V" = "0" ] || [ -z "$V" ]; then
        echo "-> 已被改回关闭状态，重新开启"
        echo 1 > "$SYSCTL" 2>/dev/null
        echo "重开后 = $(cat "$SYSCTL" 2>/dev/null)"
    fi

    # input handler 注册情况：决定音量-下 + 电源键 等组合键是否生效
    H=$(cat /proc/bus/input/handlers 2>/dev/null | tr -d '\t' | grep -c "^sysrq$")
    if [ "$H" -gt 0 ]; then
        echo "sysrq input handler: 已注册（组合键可用）"
    else
        echo "sysrq input handler: 未注册（组合键不可用，仅 /proc/sysrq-trigger 可用）"
    fi

    echo "trigger 节点: $([ -e "$TRIGGER" ] && echo 就绪 || echo 缺失)"
    echo
    echo "常用诊断命令（免 root）:"
    echo "  echo w > $TRIGGER   # 阻塞任务栈（最常用）"
    echo "  echo l > $TRIGGER   # CPU 寄存器与反汇编"
    echo "  echo n > $TRIGGER   # 处于 D 状态的任务"
    echo "  echo m > $TRIGGER   # 内存信息"
    echo "  echo t > $TRIGGER   # 软中断统计"
    echo "  echo u > $TRIGGER   # 各 CPU 负载"
    echo "  echo q > $TRIGGER   # 全进程栈（很慢）"
} >> "$OUT" 2>/dev/null