#!/system/bin/sh
# LDN-AL20 性能调优 —— late_start 阶段：重新施加 + 校验 + 记录
#
# 重要：post-fs-data.sh 执行太早，华为 init.rc 在 "on boot" 阶段会重新设置
#       vm.swappiness=100 与 read_ahead_kb=128，把早期写入的值覆盖掉。
#       因此这里（late_start，开机完成后）必须再施加一次，参数才会真正留存。
#
# 由于 SELinux 为 Enforcing 且 magisk context 无法写 /proc、/sys，
# 这里临时 setenforce 0 后写入，再 setenforce 1 恢复
# （V8 内核已开 CONFIG_SECURITY_SELINUX_DEVELOP，故 setenforce 可用）。

LOG=/data/local/tmp/perf_tune.log
log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG" 2>/dev/null; }

log "--- service.sh (late_start) ---"

# 等系统开机流程稳定，避开 Huawei 各阶段 init 的重置
sleep 25

# 临时关 SELinux
WAS_ENFORCING=0
if getenforce 2>/dev/null | grep -q Enforcing; then
  WAS_ENFORCING=1
  setenforce 0 2>/dev/null && log "setenforce 0 ok" || log "setenforce 0 FAILED"
fi

apply() {
  # I/O 调度器
  for q in /sys/block/mmcblk0/queue /sys/block/mmcblk0rpmb/queue; do
    [ -e "$q/scheduler" ] && grep -q deadline "$q/scheduler" 2>/dev/null \
      && echo deadline > "$q/scheduler" 2>/dev/null
  done
  # 预读
  [ -e /sys/block/mmcblk0/queue/read_ahead_kb ] \
    && echo 512 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null
  # 虚拟内存
  echo 70   > /proc/sys/vm/swappiness 2>/dev/null
  echo 5    > /proc/sys/vm/dirty_background_ratio 2>/dev/null
  echo 15   > /proc/sys/vm/dirty_ratio 2>/dev/null
  echo 200  > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null
  echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null
  echo 60   > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
  # interactive 调频
  D=/sys/devices/system/cpu/cpufreq/interactive
  if [ -d "$D" ]; then
    [ -e "$D/io_is_busy" ]       && echo 1     > "$D/io_is_busy"       2>/dev/null
    [ -e "$D/timer_rate" ]       && echo 15000 > "$D/timer_rate"       2>/dev/null
    [ -e "$D/go_hispeed_load" ]  && echo 85    > "$D/go_hispeed_load"  2>/dev/null
  fi
}

apply
log "first apply done"

# /vendor/etc/init/hw/init.target.rc 里有 "write /proc/sys/vm/swappiness 100"，
# 且其触发时机会晚于 late_start，会把值改回 100。
# 因此在 +60s、+180s 各补写一次，覆盖掉它的重置。
# （readahead / dirty_ratio / vfs_cache_pressure 无此问题，只需设置一次）
(
  sleep 60
  SW1=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  if [ "$SW1" != "70" ]; then
    getenforce | grep -q Enforcing && setenforce 0 2>/dev/null
    echo 70 > /proc/sys/vm/swappiness 2>/dev/null
    setenforce 1 2>/dev/null
    log "swappiness 被重置为 $SW1，+60s 补写 -> $(cat /proc/sys/vm/swappiness 2>/dev/null)"
  else
    log "+60s 复核 swappiness 保持 70"
  fi
  sleep 120
  SW2=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  if [ "$SW2" != "70" ]; then
    getenforce | grep -q Enforcing && setenforce 0 2>/dev/null
    echo 70 > /proc/sys/vm/swappiness 2>/dev/null
    setenforce 1 2>/dev/null
    log "swappiness 被重置为 $SW2，+180s 补写 -> $(cat /proc/sys/vm/swappiness 2>/dev/null)"
  else
    log "+180s 复核 swappiness 保持 70"
  fi
) &

# 恢复 SELinux（重试几次，确保不留 Permissive）
if [ "$WAS_ENFORCING" -eq 1 ]; then
  i=0
  while [ $i -lt 5 ]; do
    setenforce 1 2>/dev/null
    getenforce 2>/dev/null | grep -q Enforcing && break
    i=$((i + 1)); sleep 2
  done
fi

log "=== 最终生效值 ==="
log "scheduler      : $(cat /sys/block/mmcblk0/queue/scheduler 2>/dev/null)"
log "readahead      : $(cat /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null) KB"
log "swappiness     : $(cat /proc/sys/vm/swappiness 2>/dev/null)"
log "dirty_ratio    : $(cat /proc/sys/vm/dirty_ratio 2>/dev/null)"
log "dirty_bg_ratio : $(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null)"
log "vfs_cache_pres : $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"
log "governor       : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
log "tcp_cong       : $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
log "SELinux        : $(getenforce 2>/dev/null)"
log "=== done ==="
