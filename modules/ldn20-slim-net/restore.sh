#!/system/bin/sh
# ldn20-slim-net —— restore.sh（一键还原到原厂值）
#
# 用法：
#   su -c 'sh /data/adb/modules/ldn20-slim-net/restore.sh'      # 还原全部
#   su -c 'sh /data/adb/modules/ldn20-slim-net/restore.sh list' # 只看备份
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失"; exit 1; }

BAK=$SLIM_ROOT/backup

LIST="
net.tcp_tw_reuse:/proc/sys/net/ipv4/tcp_tw_reuse
net.tcp_tw_recycle:/proc/sys/net/ipv4/tcp_tw_recycle
net.tcp_fin_timeout:/proc/sys/net/ipv4/tcp_fin_timeout
net.tcp_fastopen:/proc/sys/net/ipv4/tcp_fastopen
net.ip_local_port_range:/proc/sys/net/ipv4/ip_local_port_range
net.tcp_max_syn_backlog:/proc/sys/net/ipv4/tcp_max_syn_backlog
net.tcp_syn_retries:/proc/sys/net/ipv4/tcp_syn_retries
net.tcp_synack_retries:/proc/sys/net/ipv4/tcp_synack_retries
net.tcp_syncookies:/proc/sys/net/ipv4/tcp_syncookies
net.tcp_rmem:/proc/sys/net/ipv4/tcp_rmem
net.tcp_wmem:/proc/sys/net/ipv4/tcp_wmem
net.tcp_moderate_rcvbuf:/proc/sys/net/ipv4/tcp_moderate_rcvbuf
net.tcp_autocorking:/proc/sys/net/ipv4/tcp_autocorking
net.tcp_mem:/proc/sys/net/ipv4/tcp_mem
net.tcp_keepalive_time:/proc/sys/net/ipv4/tcp_keepalive_time
net.tcp_keepalive_intvl:/proc/sys/net/ipv4/tcp_keepalive_intvl
net.tcp_keepalive_probes:/proc/sys/net/ipv4/tcp_keepalive_probes
net.tcp_max_orphans:/proc/sys/net/ipv4/tcp_max_orphans
net.tcp_orphan_retries:/proc/sys/net/ipv4/tcp_orphan_retries
net.tcp_max_tw_buckets:/proc/sys/net/ipv4/tcp_max_tw_buckets
net.nf_conntrack_max:/proc/sys/net/netfilter/nf_conntrack_max
net.icmp_msgs_burst:/proc/sys/net/ipv4/icmp_msgs_burst
"

if [ "$1" = "list" ]; then
  echo "=== slim-net 备份清单 ==="
  echo "$LIST" | while read -r line; do
    [ -z "$line" ] && continue
    TAG=${line%%:*}; F=${line#*:}
    [ -e "$BAK/$TAG" ] && printf "  %-28s %s\n" "$TAG" "$(cat $BAK/$TAG 2>/dev/null | tr -d '\r\n')"
  done
  echo "备份目录: $BAK"
  exit 0
fi

echo "=== slim-net 还原到原厂值 ==="
slim_se_begin
echo "$LIST" | while read -r line; do
  [ -z "$line" ] && continue
  TAG=${line%%:*}; F=${line#*:}
  if [ -e "$BAK/$TAG" ]; then
    if slim_restore "$TAG" "$F"; then
      echo "  还原 $(printf '%-28s' $TAG) -> $(slim_get $F | head -c 50)"
    else
      echo "  还原失败 $TAG"
    fi
  fi
done
slim_se_end
echo "=== 完成。彻底清理：rm -rf /data/adb/ldn20-slim ==="
