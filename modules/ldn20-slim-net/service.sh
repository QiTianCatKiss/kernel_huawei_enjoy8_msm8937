#!/system/bin/sh
# ldn20-slim-net —— service（late_start：重新施加 + 校验 + 状态输出）
#
# 与 slim-mem 同理：华为 init.rc 与 netd 会在 boot 阶段重设部分网络参数，
# 这里在 late_start 再施加一次，并做一次延后复核。
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失，放弃"; exit 0; }

slim_log "--- slim-net service (late_start) ---"
sleep 30

slim_se_begin

# 只在"被改回去了"时才重写，避免无谓 I/O
recheck() {
  for CHK in /proc/sys/net/ipv4/tcp_tw_reuse:1 \
             /proc/sys/net/ipv4/tcp_fin_timeout:15 \
             /proc/sys/net/ipv4/tcp_fastopen:1 \
             /proc/sys/net/ipv4/tcp_syncookies:1 \
             /proc/sys/net/ipv4/tcp_keepalive_time:120; do
    P=${CHK%%:*}; WANT=${CHK##*:}
    [ -e "$P" ] || continue
    GOT=$(slim_get "$P")
    [ "$GOT" = "$WANT" ] || slim_setnum "net.$(basename $P)" "$P" "$WANT"
  done
}
recheck
slim_log "首次复核完成"

# 延后再查一次（netd 可能在稍后重设）
(
  sleep 120
  getenforce 2>/dev/null | grep -q Enforcing && setenforce 0 2>/dev/null
  recheck
  getenforce 2>/dev/null | grep -q Permissive && setenforce 1 2>/dev/null
) &

slim_se_end

# ============================================================ 状态输出
DUMP=/data/local/tmp/slim_net_status.txt
{
  echo "=== LDN-AL20 slim-net 生效值 ==="
  echo "日期        : $(date)"
  echo "--- 连接复用 ---"
  echo "tw_reuse    : $(slim_get /proc/sys/net/ipv4/tcp_tw_reuse)"
  echo "tw_recycle  : $(slim_get /proc/sys/net/ipv4/tcp_tw_recycle)"
  echo "fin_timeout : $(slim_get /proc/sys/net/ipv4/tcp_fin_timeout)"
  echo "max_tw_buck : $(slim_get /proc/sys/net/ipv4/tcp_max_tw_buckets)"
  echo "max_orphans : $(slim_get /proc/sys/net/ipv4/tcp_max_orphans)"
  echo "--- Fast Open ---"
  echo "tcp_fastopen: $(slim_get /proc/sys/net/ipv4/tcp_fastopen)"
  echo "--- 端口 ---"
  echo "port_range  : $(slim_get /proc/sys/net/ipv4/ip_local_port_range)"
  echo "--- 握手 ---"
  echo "syn_backlog : $(slim_get /proc/sys/net/ipv4/tcp_max_syn_backlog)"
  echo "syn_retries : $(slim_get /proc/sys/net/ipv4/tcp_syn_retries)"
  echo "synack_retr : $(slim_get /proc/sys/net/ipv4/tcp_synack_retries)"
  echo "syncookies  : $(slim_get /proc/sys/net/ipv4/tcp_syncookies)"
  echo "--- 缓冲 ---"
  echo "tcp_rmem    : $(slim_get /proc/sys/net/ipv4/tcp_rmem)"
  echo "tcp_wmem    : $(slim_get /proc/sys/net/ipv4/tcp_wmem)"
  echo "tcp_mem     : $(slim_get /proc/sys/net/ipv4/tcp_mem)"
  echo "mod_rcvbuf  : $(slim_get /proc/sys/net/ipv4/tcp_moderate_rcvbuf)"
  echo "autocorking : $(slim_get /proc/sys/net/ipv4/tcp_autocorking)"
  echo "--- keepalive ---"
  echo "ka_time     : $(slim_get /proc/sys/net/ipv4/tcp_keepalive_time)"
  echo "ka_intvl    : $(slim_get /proc/sys/net/ipv4/tcp_keepalive_intvl)"
  echo "ka_probes   : $(slim_get /proc/sys/net/ipv4/tcp_keepalive_probes)"
  echo "--- 拥塞控制 ---"
  echo "available   : $(slim_get /proc/sys/net/ipv4/tcp_available_congestion_control)"
  echo "current     : $(slim_get /proc/sys/net/ipv4/tcp_congestion_control)"
  echo "--- conntrack ---"
  echo "ct_max      : $(slim_get /proc/sys/net/netfilter/nf_conntrack_max)"
  echo "ct_count    : $(slim_get /proc/sys/net/netfilter/nf_conntrack_count)"
  echo "--- ICMP ---"
  echo "msgs_per_sec: $(slim_get /proc/sys/net/ipv4/icmp_msgs_per_sec)"
  echo "msgs_burst  : $(slim_get /proc/sys/net/ipv4/icmp_msgs_burst)"
  echo "ratelimit   : $(slim_get /proc/sys/net/ipv4/icmp_ratelimit)"
  echo "--- 接口 ---"
  echo "wlan0       : $(slim_get /sys/class/net/wlan0/address)"
  echo "IPv6 disable: $(slim_get /proc/sys/net/ipv6/conf/all/disable_ipv6)"
  echo "=========================="
} > "$DUMP" 2>/dev/null

slim_log "状态已写入 $DUMP"
slim_log "=== slim-net service done ==="
