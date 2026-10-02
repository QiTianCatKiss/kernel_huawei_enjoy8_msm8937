#!/system/bin/sh
# slim_status.sh —— 四个 slim 模块的统一状态检查
#
# 用法：
#   su -c 'sh /data/adb/ldn20-slim/slim_status.sh'
#
# 一次性汇总四个模块的生效情况，并标出「被华为 init.rc 覆盖失效」的项。
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "无法读取 slim_common.sh"; exit 1; }

# check <期望值> <路径> <说明>
PASS=0; FAIL=0; SKIP=0
check() {
  WANT=$1; P=$2; DESC=$3
  if [ ! -e "$P" ]; then
    printf "  [ -- ] %-28s 节点不存在（跳过）\n" "$DESC"
    SKIP=$((SKIP + 1))
    return
  fi
  GOT=$(slim_get "$P" | tr -d '\r')
  if [ "$GOT" = "$WANT" ]; then
    printf "  [ OK ] %-28s = %s\n" "$DESC" "$GOT"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %-28s = %s（期望 %s）\n" "$DESC" "$GOT" "$WANT"
    FAIL=$((FAIL + 1))
  fi
}

echo "=========================================="
echo " LDN-AL20 slim 系列状态汇总"
echo " 时间: $(date)"
echo " SELinux: $(getenforce 2>/dev/null)"
echo " 内核  : $(uname -a 2>/dev/null | cut -c1-60)"
echo "=========================================="

echo
echo "【slim-mem 内存与回收】"
check 20    /proc/sys/vm/direct_swappiness "direct_swappiness"
check 50    /proc/sys/vm/vfs_cache_pressure "vfs_cache_pressure"
check 15    /proc/sys/vm/dirty_ratio        "dirty_ratio"
check 5     /proc/sys/vm/dirty_background_ratio "dirty_background_ratio"
check 200   /proc/sys/vm/dirty_expire_centisecs "dirty_expire_centisecs"
check 1500  /proc/sys/vm/dirty_writeback_centisecs "dirty_writeback_centisecs"
check 0     /proc/sys/vm/laptop_mode        "laptop_mode"
check 1     /proc/sys/vm/oom_kill_allocating_task "oom_kill_allocating_task"
check 256   /sys/block/mmcblk0/queue/read_ahead_kb "read_ahead_kb"
check 2     /sys/block/zram0/max_comp_streams "zram max_comp_streams"
check lz4   /sys/block/zram0/comp_algorithm   "zram comp_algorithm"
# swappiness / min_free_kbytes / scheduler 需要动态期望值
SW=$(slim_get /proc/sys/vm/swappiness)
if [ "$SW" = "70" ]; then
  printf "  [ OK ] %-28s = %s\n" "swappiness" "$SW"
else
  printf "  [FAIL] %-28s = %s（期望 70，被 init.rc 覆盖）\n" "swappiness" "$SW"
  FAIL=$((FAIL + 1))
fi
MFK=$(slim_get /proc/sys/vm/min_free_kbytes)
if [ -n "$MFK" ] && [ "$MFK" -ge 3072 ] 2>/dev/null; then
  printf "  [ OK ] %-28s = %s KB\n" "min_free_kbytes" "$MFK"
else
  printf "  [FAIL] %-28s = %s（期望 >= 3072）\n" "min_free_kbytes" "${MFK:-N/A}"
  FAIL=$((FAIL + 1))
fi
SCHED=$(slim_get /sys/block/mmcblk0/queue/scheduler)
case "$SCHED" in
  *deadline*) printf "  [ OK ] %-28s = %s\n" "I/O 调度器" "$SCHED"; PASS=$((PASS+1)) ;;
  *) printf "  [FAIL] %-28s = %s（期望 deadline）\n" "I/O 调度器" "${SCHED:-N/A}"; FAIL=$((FAIL+1)) ;;
esac
# LMKD
echo "  -- LMKD --"
for P in minfree adj cost debug_level; do
  F=/sys/module/lowmemorykiller/parameters/$P
  if [ -e "$F" ]; then
    printf "  [ OK ] %-28s = %s\n" "lmk.$P" "$(slim_get $F)"
  else
    printf "  [ -- ] %-28s 节点不存在\n" "lmk.$P"
  fi
done

echo
echo "【slim-net 网络栈】"
check 1     /proc/sys/net/ipv4/tcp_tw_reuse    "tcp_tw_reuse"
check 0     /proc/sys/net/ipv4/tcp_tw_recycle  "tcp_tw_recycle"
check 15    /proc/sys/net/ipv4/tcp_fin_timeout "tcp_fin_timeout"
check 1     /proc/sys/net/ipv4/tcp_fastopen    "tcp_fastopen"
check 1     /proc/sys/net/ipv4/tcp_syncookies  "tcp_syncookies"
check 120   /proc/sys/net/ipv4/tcp_keepalive_time "tcp_keepalive_time"
check 15    /proc/sys/net/ipv4/tcp_keepalive_intvl "tcp_keepalive_intvl"
check 4     /proc/sys/net/ipv4/tcp_keepalive_probes "tcp_keepalive_probes"
check 1     /proc/sys/net/ipv4/tcp_moderate_rcvbuf "tcp_moderate_rcvbuf"
check 1     /proc/sys/net/ipv4/tcp_autocorking "tcp_autocorking"
PR=$(slim_get /proc/sys/net/ipv4/ip_local_port_range)
if [ "$PR" = "1024 65535" ]; then
  printf "  [ OK ] %-28s = %s\n" "ip_local_port_range" "$PR"
else
  printf "  [FAIL] %-28s = %s（期望 '1024 65535'）\n" "ip_local_port_range" "${PR:-N/A}"
  FAIL=$((FAIL + 1))
fi
echo "  -- 信息 --"
echo "  拥塞控制    : $(slim_get /proc/sys/net/ipv4/tcp_congestion_control)"
echo "  可用算法    : $(slim_get /proc/sys/net/ipv4/tcp_available_congestion_control)"
echo "  tcp_mem     : $(slim_get /proc/sys/net/ipv4/tcp_mem)"
echo "  conntrack   : $(slim_get /proc/sys/net/netfilter/nf_conntrack_count) / $(slim_get /proc/sys/net/netfilter/nf_conntrack_max)"

echo
echo "【slim-boot 开机与后台】"
if [ -s "$SLIM_ROOT/boot/stopped_services" ]; then
  echo "  已停止服务  : $(grep -c . $SLIM_ROOT/boot/stopped_services 2>/dev/null) 个"
  cat "$SLIM_ROOT/boot/stopped_services" | sed 's/^/    - /'
else
  echo "  已停止服务  : (无)"
fi
if [ -s "$SLIM_ROOT/boot/frozen_packages" ]; then
  echo "  已冻结包    : $(grep -c . $SLIM_ROOT/boot/frozen_packages 2>/dev/null) 个"
  cat "$SLIM_ROOT/boot/frozen_packages" | sed 's/^/    - /'
else
  echo "  已冻结包    : (无)"
fi
echo "  当前进程数  : $(ps -A 2>/dev/null | wc -l)"

echo
echo "【slim-debug 日志与上报】"
echo "  printk      : $(slim_get /proc/sys/kernel/printk)"
echo "  dmesg_restr : $(slim_get /proc/sys/kernel/dmesg_restrict)"
echo "  logtag 项数 : $(grep -c . $SLIM_ROOT/debug/props 2>/dev/null || echo 0)"
echo "  atrace      : $(getprop persist.atrace.enabled 2>/dev/null)"
echo "  strictmode  : $(getprop persist.sys.strictmode.disable 2>/dev/null)"
if [ -e /proc/reboot_watchdog ]; then
  echo "  reboot_wdt  : 存在（正常，未动）"
else
  echo "  reboot_wdt  : 不存在"
fi

echo
echo "--- 资源现状 ---"
grep -E "MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree" /proc/meminfo 2>/dev/null | sed 's/^/  /'
echo "  zram 原数据 : $(slim_get /sys/block/zram0/orig_data_size)"
echo "  zram 实际用 : $(slim_get /sys/block/zram0/mem_used_total)"
echo "  CPU 在线    : $(slim_get /sys/devices/system/cpu/online)"
echo "  CPU governor: $(slim_get /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

echo
echo "=========================================="
echo " 统计: 通过 $PASS | 失败 $FAIL | 跳过 $SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo " 有失败项：多半是华为 init.rc 在 boot 阶段重置了参数。"
  echo " 模块已在 +90s/+240s 补写，若仍失败请查看 $SLIM_LOG"
fi
echo "=========================================="
