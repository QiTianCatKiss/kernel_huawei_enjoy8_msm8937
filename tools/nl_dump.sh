#!/system/bin/sh
# 探测内核 netlink 槽位占用：/proc/net/netlink 是只读 dump，
# 改为直接看有哪些 netlink 家族注册（通过 /proc/net/netlink 的协议号列）
echo "=== /proc/net/netlink (first 40 lines) ==="
head -40 /proc/net/netlink 2>&1
echo
echo "=== count of entries per protocol ==="
awk 'NR>1 {print $5}' /proc/net/netlink 2>/dev/null | sort -n | uniq -c
echo
echo "=== all protocols seen ==="
awk 'NR>1 {print $5}' /proc/net/netlink 2>/dev/null | sort -n | tr '\n' ' '
echo
