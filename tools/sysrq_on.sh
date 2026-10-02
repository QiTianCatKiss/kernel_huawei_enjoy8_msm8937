#!/system/bin/sh
# sysrq 调试入口 —— 无需重编译内核
#
# 原理（本机内核 3.18 已验证）：
#   CONFIG_MAGIC_SYSRQ=y，drivers/tty/sysrq.o 已编译进内核，
#   /proc/sysrq-trigger 已注册（drivers/tty/sysrq.c:1140）。
#   sysrq_enabled 默认 = CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE = 0x0（关闭）。
#   kernel/sysctl.c:1041 注册了 kernel.sysrq sysctl，写入后调用
#   sysrq_toggle_support()，立即向 debugfs 注册 sysrq input handler。
#
# 用法：
#   sh sysrq_on.sh          # 开启（写 1 = 全开）
#   sh sysrq_on.sh off      # 关闭（写 0）
#   sh sysrq_on.sh status   # 查看状态
#   sh sysrq_on.sh cmd w    # 触发一次 sysrq 动作（需已开启）
#
# 注意：/proc/sysrq-trigger 的写入走 __handle_sysrq(c, false)，
#       check_mask=false，会绕过掩码直接执行。
#       因此本脚本在开启后也能直接触发，无需再写 sysctl。

SYSCTL=/proc/sys/kernel/sysrq
TRIGGER=/proc/sysrq-trigger

# sysrq 动作字母 → 说明（子命令 help 时输出）
show_help() {
    echo "可用动作（字母）:"
    echo "  b  立即重启"
    echo "  c  Ctrl+Alt+Del 软重启"
    echo "  i  SIGKILL 所有进程（慎用）"
    echo "  l  显示所有 CPU 的寄存器 + 反汇编 + 栈"
    echo "  m  显示内存信息"
    echo "  n  显示实时任务 D 状态（未中断睡眠）"
    echo "  p  显示调度器信息"
    echo "  q  全进程栈回溯（很慢）"
    echo "  r  显示 PREEMPT 延迟"
    echo "  s  显示内存占用 top"
    echo "  t  显示软中断统计"
    echo "  u  显示各 CPU 负载"
    echo "  w  显示阻塞任务（D 状态）栈"
    echo "  x  显示寄存器"
    echo "Full help: cat /proc/sysrq-trigger --help" 2>/dev/null
}

status() {
    if [ -e "$SYSCTL" ]; then
        V=$(cat "$SYSCTL" 2>/dev/null)
        echo "sysctl   : $SYSCTL = $V"
        [ "$V" = "0" ] && echo "  -> 已关闭" || echo "  -> 已开启（1=全开，2/4/8.. 为位掩码）"
    else
        echo "sysctl   : $SYSCTL 不存在"
        echo "  -> 内核可能未开 CONFIG_MAGIC_SYSRQ"
    fi

    if [ -e "$TRIGGER" ]; then
        echo "trigger  : $TRIGGER 已就绪"
        # 检查 input handler 是否真的注册了：debugfs 下看 tracefs 之类不可靠，
        # 改用能否读到 handler 列表（3.18 无 /sys/class/input 权限时降级）
        H=$(cat /proc/bus/input/handlers 2>/dev/null | tr -d '\t' | grep -c "^sysrq$")
        if [ "$H" -gt 0 ]; then
            echo "  -> sysrq input handler 已注册（可用组合键触发）"
        else
            echo "  -> sysrq input handler 未注册（普通按键方式不可用，请用 trigger 节点）"
        fi
    else
        echo "trigger  : $TRIGGER 不存在"
    fi
}

case "${1:-help}" in
    off)
        echo 0 > "$SYSCTL" 2>/dev/null && echo "已关闭 sysrq" || echo "写入 $SYSCTL 失败"
        ;;
    on|"")
        if echo 1 > "$SYSCTL" 2>/dev/null; then
            echo "已开启 sysrq（全功能）"
        else
            echo "写入 $SYSCTL 失败 —— SELinux 可能拦截，试试 su -c"
        fi
        ;;
    status|st)
        status
        ;;
    cmd)
        if [ -z "$2" ]; then
            echo "用法: sh sysrq_on.sh cmd <字母>"
            echo
            show_help
            exit 1
        fi
        if [ ! -e "$TRIGGER" ]; then
            echo "!! $TRIGGER 不存在，先执行 sh sysrq_on.sh on"
            exit 1
        fi
        echo "$2" > "$TRIGGER" 2>/dev/null \
            && echo "已触发 sysrq '$2'，输出见 dmesg" \
            || echo "触发失败"
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        echo "$2" > "$TRIGGER" 2>/dev/null && echo "已触发 '$2'" || echo "触发失败"
        ;;
esac