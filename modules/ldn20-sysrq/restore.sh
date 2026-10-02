#!/system/bin/sh
# ldn20-sysrq —— restore（关闭 sysrq）
SYSCTL=/proc/sys/kernel/sysrq
if echo 0 > "$SYSCTL" 2>/dev/null; then
    echo "sysrq 已关闭：$(cat "$SYSCTL" 2>/dev/null)"
else
    echo "关闭失败，试试: su -c 'echo 0 > $SYSCTL'"
fi
# 注意：sysrq input handler 的注销在 3.18 里由 sysrq_toggle_support()
# 自动完成（会调用 sysrq_unregister_handler()），无需重启。
echo "如仍可触发，重启后生效。"