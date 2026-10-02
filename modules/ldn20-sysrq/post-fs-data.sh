#!/system/bin/sh
# ldn20-sysrq —— post-fs-data（开启 Magic SysRq）
#
# 【为什么这个模块能工作】本机内核 3.18.66 已验证：
#   CONFIG_MAGIC_SYSRQ=y                    .config 已有
#   drivers/tty/sysrq.o                     已编译进内核
#   /proc/sysrq-trigger                     drivers/tty/sysrq.c:1140 已注册(S_IWUSR)
#   kernel.sysrq sysctl                     kernel/sysctl.c:1041 已注册(0644)
#   sysrq_enabled 初值 = 0x0                关闭状态
#
#   开启路径：写 /proc/sys/kernel/sysrq
#     -> sysrq_sysctl_handler()   kernel/sysctl.c:221
#     -> sysrq_toggle_support()   drivers/tty/sysrq.c:1063
#     -> sysrq_register_handler() 注册 input handler
#
# 【与 V12-debug 内核的区别】
#   本模块不重编译内核，只开 sysrq。ftrace / kprobes 需要 V12-debug 内核。
#
# 【安全说明】
#   开启后 sysrq 组合键生效，误触可能直接重启或杀掉进程。
#   本模块在 post-fs-data 阶段开启（此时用户尚未开始使用），
#   关闭方式：su -c 'echo 0 > /proc/sys/kernel/sysrq'
#   或卸载本模块后重启。

SYSCTL=/proc/sys/kernel/sysrq
TRIGGER=/proc/sysrq-trigger
OUT=/data/local/tmp/sysrq_status.txt
LOG=/data/adb/ldn20-sysrq.log

log() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
    echo "$*"
}

: > "$OUT" 2>/dev/null

if [ ! -e "$TRIGGER" ]; then
    log "sysrq: /proc/sysrq-trigger 不存在 —— 内核未开 CONFIG_MAGIC_SYSRQ"
    echo "内核未编译 sysrq，需刷 V12-debug 内核" >> "$OUT"
    exit 0
fi

# 记录开启前的值（便于还原）
OLD=$(cat "$SYSCTL" 2>/dev/null)
echo "原有 sysrq_enabled = $OLD" >> "$OUT"

if echo 1 > "$SYSCTL" 2>/dev/null; then
    NEW=$(cat "$SYSCTL" 2>/dev/null)
    if [ "$NEW" = "1" ]; then
        log "sysrq 已开启（enabled=$NEW）"
        echo "状态: 已开启（全功能）" >> "$OUT"
    else
        # 写进去了但回读不一致 —— 可能是 SELinux 或华为改写
        log "sysrq 写入成功但回读为 $NEW，可能被改写"
        echo "状态: 写入成功但回读=$NEW（可能被改写）" >> "$OUT"
    fi
else
    log "sysrq 开启失败（SELinux 可能拦截）"
    echo "状态: 开启失败" >> "$OUT"
    echo "尝试: su -c 'echo 1 > $SYSCTL'" >> "$OUT"
fi

# 记录 trigger 可用性
echo "/proc/sysrq-trigger: $([ -e "$TRIGGER" ] && echo 已就绪 || echo 缺失)" >> "$OUT"
echo "免 root 触发方式: echo w > $TRIGGER" >> "$OUT"

# 部署便捷脚本
mkdir -p /data/adb/ldn20-sysrq 2>/dev/null
if [ -f /data/adb/modules/ldn20-sysrq/sysrq_on.sh ]; then
    cp -f /data/adb/modules/ldn20-sysrq/sysrq_on.sh /data/adb/ldn20-sysrq/ 2>/dev/null
fi

log "自检完成，状态见 $OUT"