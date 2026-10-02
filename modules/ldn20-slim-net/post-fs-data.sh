#!/system/bin/sh
# ldn20-slim-mem 的公共库由 slim-mem 模块提供，本模块不自带副本，
# 但为保证单独安装 slim-net 也能工作，缺失时从本模块目录找。
SLIMDIR=/data/adb/ldn20-slim
MYDIR=/data/adb/modules/ldn20-slim-net
mkdir -p "$SLIMDIR/lib" "$SLIMDIR/backup" 2>/dev/null

# --- 引导公共库 ---
# 优先用已部署的；没有就从 ldn20-slim-core 取（它是唯一携带公共库的包）。
# 即便 core 没装，本模块也会扫描任意已安装的 slim-* 包来补齐。
if [ ! -e "$SLIMDIR/lib/slim_common.sh" ]; then
  for D in "$MYDIR" /data/adb/modules/ldn20-slim-core /data/adb/modules/ldn20-slim-*; do
    if [ -e "$D/slim_common.sh" ]; then
      cp -f "$D/slim_common.sh" "$SLIMDIR/lib/" 2>/dev/null && break
    fi
  done
fi
if [ ! -e "$SLIMDIR/slim_status.sh" ]; then
  for D in "$MYDIR" /data/adb/modules/ldn20-slim-core /data/adb/modules/ldn20-slim-*; do
    if [ -e "$D/slim_status.sh" ]; then
      cp -f "$D/slim_status.sh" "$SLIMDIR/" 2>/dev/null
      chmod 755 "$SLIMDIR/slim_status.sh" 2>/dev/null
      break
    fi
  done
fi

. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失，请先安装 ldn20-slim-core"; exit 0; }

slim_init
slim_log "=== slim-net post-fs-data start ==="

slim_se_begin

# ============================================================ 1. TIME_WAIT 累积
# 手机上最常见的"用久了就上不了网"：短连接海量 TIME_WAIT 占满本地端口，
# 新建连接只能等 60s 超时回收。
# tcp_tw_reuse=1 允许在 TIME_WAIT 超过 1s 后复用（3.18 的安全判据：时间戳严格递增），
# 对移动网络（源 IP 频繁变化）是安全的。
# 附带收益：省下内核为 TIME_WAIT 保留的内存。
slim_setnum net.tcp_tw_reuse /proc/sys/net/ipv4/tcp_tw_reuse 1

# tcp_tw_recycle 在移动网络（NAT 后多设备共用 IP）会导致丢包，已被 Linux 内核
# 默认关闭（4.12+ 语义变更）。本机 3.18 仍有此节点，但**不要开** —— 明确写 0。
slim_setnum net.tcp_tw_recycle /proc/sys/net/ipv4/tcp_tw_recycle 0

# 缩短 fin_timeout：FIN_WAIT2 状态孤儿 socket 的超时（默认 60s），
# 手机上不会有"半关闭长连接"的正常业务，缩到 15s 可更快回收 fd。
slim_setnum net.tcp_fin_timeout /proc/sys/net/ipv4/tcp_fin_timeout 15

# ============================================================ 2. TCP Fast Open
# 【本机内核实际状态】net/ipv4/sysctl_net_ipv4.c 中 tcp_fastopen 节点
# 是**无条件注册**的（不在 #ifdef CONFIG_TCP_FASTOPEN 内），
# 且 stock config 虽无 CONFIG_TCP_FASTOPEN=y，该文件仍编译了 fastopen 代码，
# 因此该 sysctl 存在且可写。内核未打 TFO patch 时，
# 该值只是让内核接受/记录客户端侧的 TFO 选项。
# 值：3 = 客户端+服务端都启用（0x01 client | 0x02 server）
# 用 1（仅客户端）风险最小：只让本机发起连接时带上 cookie，
# 省掉一次 RTT，服务端不启用也不影响。
slim_setnum net.tcp_fastopen /proc/sys/net/ipv4/tcp_fastopen 1

# ============================================================ 3. 端口范围
# 默认 32768-60999（约 28000 个）。同时跑应用 + 热点 + adb tcpip 时不够用，
# 扩到 1024-65535（约 64000 个），并避开已注册的 5555/8080 等。
slim_setnum net.ip_local_port_range /proc/sys/net/ipv4/ip_local_port_range "1024 65535"

# ============================================================ 4. SYN 队列与半连接
# tcp_max_syn_backlog 默认 128（无 syncookies 时偏小），
# 配合 tcp_syncookies=1（默认）可抗突发。
slim_setnum net.tcp_max_syn_backlog /proc/sys/net/ipv4/tcp_max_syn_backlog 1024
# tcp_syn_retries / tcp_synack_retries：默认 6/5，总超时约 127s。
# 手机网络质量波动大，重试太久会让用户以为"坏了"。
# 降到 4/3（约 31s）能更快给出失败。
slim_setnum net.tcp_syn_retries   /proc/sys/net/ipv4/tcp_syn_retries   4
slim_setnum net.tcp_synack_retries /proc/sys/net/ipv4/tcp_synack_retries 3
# 确认 syncookies 开启（防 SYN flood，同时在内存紧张时降级丢包）
slim_setnum net.tcp_syncookies /proc/sys/net/ipv4/tcp_syncookies 1

# ============================================================ 5. 缓冲区
# 4G/无线链路 RTT 高且抖动大，默认 rmem/wmem 偏小。
# 但不能设太大 —— 每条连接都预留会吃掉小内存机的宝贵 RAM。
# 3 档 4096/131072/6291456（4K/128K/6M）已足够覆盖几 MB/s 的单流。
# 关键是把 auto-tuning 打开（下面 tcp_moderate_rcvbuf）。
slim_setnum net.tcp_rmem /proc/sys/net/ipv4/tcp_rmem "4096 131072 6291456"
slim_setnum net.tcp_wmem /proc/sys/net/ipv4/tcp_wmem "4096 16384 4194304"

# 接收缓冲自动调节：让内核按实际吞吐放大 rmem（省内存同时不牺牲速度）
slim_setnum net.tcp_moderate_rcvbuf /proc/sys/net/ipv4/tcp_moderate_rcvbuf 1
# 发送缓冲自动调节
slim_setnum net.tcp_autocorking /proc/sys/net/ipv4/tcp_autocorking 1

# ============================================================ 6. tcp_mem（按总内存自适应）
# tcp_mem 是 3 元组「低于,压力,高于」，单位页。
# 超过"压力"值会开始丢包+进入内存回收，高于"高于"值直接拒绝分配。
# 默认由内存大小算出，2GB 机上偏低（表现为网络线程被内存回收打断）。
# 按实际内存计算，保证不与总内存冲突。
MEMTOTAL_KB=0
[ -r /proc/meminfo ] && MEMTOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
case "$MEMTOTAL_KB" in
  ''|*[!0-9]*) MEMTOTAL_KB=0 ;;
esac
if [ "$MEMTOTAL_KB" -gt 2500000 ] 2>/dev/null; then
  # 3GB：约 10MB / 14MB / 18MB
  TCP_MEM="2560 3584 4608"
elif [ "$MEMTOTAL_KB" -gt 1500000 ] 2>/dev/null; then
  # 2GB：约 7MB / 10MB / 13MB
  TCP_MEM="1792 2560 3328"
else
  TCP_MEM="1024 1536 2048"
fi
slim_log "MemTotal=${MEMTOTAL_KB}KB → tcp_mem = $TCP_MEM"
slim_setnum net.tcp_mem /proc/sys/net/ipv4/tcp_mem "$TCP_MEM"

# ============================================================ 7. keepalive
# 默认 keepalive_time=7200s（2 小时才发第一个探测），
# 对 NAT 超时短的运营商网络（通常 30~300s）来说毫无意义 ——
# 链路早被中间设备断了，本端却还以为通着。
# 降到 120s，间隔 15s，探测 4 次（约 180s 内判定失活），
# 让「断网后不自愈」变成「快速感知并重建」。
slim_setnum net.tcp_keepalive_time   /proc/sys/net/ipv4/tcp_keepalive_time   120
slim_setnum net.tcp_keepalive_intvl  /proc/sys/net/ipv4/tcp_keepalive_intvl  15
slim_setnum net.tcp_keepalive_probes /proc/sys/net/ipv4/tcp_keepalive_probes 4

# ============================================================ 8. 孤儿连接与内存
# tcp_max_orphans 默认 16384；太多孤儿 socket 会占内存。
# 降到 8192，配合 orphan_retries 缩短。
slim_setnum net.tcp_max_orphans      /proc/sys/net/ipv4/tcp_max_orphans      8192
slim_setnum net.tcp_orphan_retries   /proc/sys/net/ipv4/tcp_orphan_retries   2
# tcp_max_tw_buckets 是系统级 TIME_WAIT 上限，与 tcp_tw_reuse 配合放开
slim_setnum net.tcp_max_tw_buckets   /proc/sys/net/ipv4/tcp_max_tw_buckets   16384

# ============================================================ 9. 慢启动后的空闲恢复
# tcp_slow_start_after_idle=1（默认）：连接空闲后重新走慢启动。
# 对反复小请求的场景（比如轮询）代价高。
# 关闭后空闲恢复直接进拥塞避免阶段。移动网络抖动大，
# 保守起见**保持 1**，只记录不改（若用户反馈上网慢可手动改）。
# slim_setnum net.tcp_slow_start_after_idle /proc/sys/net/ipv4/tcp_slow_start_after_idle 0

# ============================================================ 10. conntrack
# nf_conntrack_max 默认 = 内存/16384/2，2GB 机约 65536。
# 热点开启时连接数可能上万，表不够会丢连接（表现为"开了热点别人连不上"）。
# 提到 16384（足够 2GB 机的热点场景），同时上限别设太夸张以免吃内存。
CT=/proc/sys/net/netfilter/nf_conntrack_max
if [ -e "$CT" ]; then
  CUR_CT=$(slim_get $CT)
  slim_log "conntrack_max 原值 = ${CUR_CT:-N/A}"
  case "$CUR_CT" in
    ''|*[!0-9]*) ;;
    *) slim_setnum net.nf_conntrack_max "$CT" 16384 ;;
  esac
else
  slim_log "无 nf_conntrack_max（未编 netfilter？）"
fi

# ============================================================ 11. ICMP 限速
# 默认 icmp_msgs_per_sec=1000、icmp_msgs_burst=50。
# 某些应用会发大量 ICMP（ping 测试、网络诊断），
# 超限后内核会连带压制其它 ICMP（含必要的目的不可达），表现为"网突然不通"。
# 适度提高 burst 避免误伤。
slim_setnum net.icmp_msgs_burst /proc/sys/net/ipv4/icmp_msgs_burst 100

# ============================================================ 12. IPv6
# 【默认不动】IPv6 在国内运营商网络下经常"半可用"（拿到地址但不通），
# 会让应用的连接尝试浪费 3~10 秒在 v6 超时上。
# 但直接 disable_ipv6 有副作用（部分 app 依赖 v6 做 socket 探测），
# 因此本模块**不改** IPv6，只把节点暴露出来供用户自行决定。
# 需要关的话手动执行：echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
slim_log "IPv6 保持原状（需关闭请手动 echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6）"

slim_se_end
slim_log "=== slim-net post-fs-data done ==="
