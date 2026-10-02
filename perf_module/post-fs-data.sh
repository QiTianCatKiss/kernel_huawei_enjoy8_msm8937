#!/system/bin/sh
# LDN-AL20 性能调优 —— 开机早期阶段
#
# 背景：本机 SELinux 为 Enforcing，magisk context 无法写 /proc/sys 与部分 /sys。
# 原厂内核未开 CONFIG_SECURITY_SELINUX_DEVELOP，setenforce 直接报 Invalid argument。
# V8 内核打开了 SELINUX_DEVELOP，因此可以：
#   临时 setenforce 0 -> 写入调参 -> setenforce 1 恢复
# 这样既完成调优，又不长期牺牲 SELinux 防护。
#
# 所有写入都做存在性判断与失败容忍，绝不影响开机。

LOG=/data/local/tmp/perf_tune.log
: > "$LOG" 2>/dev/null
log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG" 2>/dev/null; }

log "=== perf tune start ==="

# ---- 1. 临时关闭 SELinux 以便写入（V8 内核支持）----
ENF_BEFORE=$(getenforce 2>/dev/null)
log "SELinux before: $ENF_BEFORE"
if [ "$ENF_BEFORE" = "Enforcing" ]; then
  setenforce 0 2>/dev/null && log "setenforce 0 ok" || log "setenforce 0 FAILED(内核未开 SELINUX_DEVELOP?)"
fi

# ---- 2. I/O 调度器：闪存上 deadline 延迟最低 ----
# V8 已把编译默认改为 deadline，这里显式设置做双保险（并覆盖 rpmb 之外的分区）
for blk in /sys/block/mmcblk0/queue /sys/block/mmcblk0rpmb/queue; do
  if [ -e "$blk/scheduler" ]; then
    # 先确认 deadline 真的可用，避免写了一个不存在的调度器
    if grep -q deadline "$blk/scheduler" 2>/dev/null; then
      echo deadline > "$blk/scheduler" 2>/dev/null && log "iosched $(basename $(dirname $blk)) -> deadline" \
        || log "iosched write failed: $blk"
    else
      log "deadline not available in $blk: $(cat $blk/scheduler 2>/dev/null)"
    fi
  fi
done

# ---- 3. 预读：加大到 512KB，加快应用/数据库加载 ----
for blk in /sys/block/mmcblk0/queue; do
  [ -e "$blk/read_ahead_kb" ] && echo 512 > "$blk/read_ahead_kb" 2>/dev/null \
    && log "readahead -> 512KB"
done

# ---- 4. 虚拟内存 ----
# swappiness: 原厂 100 偏激进，zram 压缩/解压要在 4 颗 A53 上花 CPU；
#             降到 70 减少压缩开销，同时仍保留 zram 的多任务收益。
echo 70 > /proc/sys/vm/swappiness 2>/dev/null && log "swappiness -> 70"

# 脏页回写：更早、更平滑地回写，避免攒太多后一次性刷盘造成卡顿
echo 5  > /proc/sys/vm/dirty_background_ratio 2>/dev/null && log "dirty_background_ratio -> 5"
echo 15 > /proc/sys/vm/dirty_ratio 2>/dev/null && log "dirty_ratio -> 15"
echo 200  > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null && log "dirty_expire_centisecs -> 200"
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null && log "dirty_writeback_centisecs -> 1500"

# 降低回收缓存倾向，尽量保住文件页缓存（应用二次启动更快）
echo 60 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null && log "vfs_cache_pressure -> 60"

# ---- 5. interactive 调频：更积极地升频 ----
CPUDIR=/sys/devices/system/cpu/cpufreq/interactive
if [ -d "$CPUDIR" ]; then
  # io_is_busy=1：把 I/O 等待计入 CPU 负载，避免在存储操作时降频（对流畅度影响明显）
  [ -e "$CPUDIR/io_is_busy" ] && echo 1 > "$CPUDIR/io_is_busy" 2>/dev/null && log "io_is_busy -> 1"
  # 缩短采样周期，更快响应负载变化
  [ -e "$CPUDIR/timer_rate" ] && echo 15000 > "$CPUDIR/timer_rate" 2>/dev/null && log "timer_rate -> 15000"
  # 降低升到高频的门槛，更早升频
  [ -e "$CPUDIR/go_hispeed_load" ] && echo 85 > "$CPUDIR/go_hispeed_load" 2>/dev/null && log "go_hispeed_load -> 85"
  log "interactive tuned"
else
  log "no interactive governor dir: $CPUDIR"
fi

# ---- 6. 恢复 SELinux ----
if [ "$ENF_BEFORE" = "Enforcing" ]; then
  setenforce 1 2>/dev/null && log "setenforce 1 restored"
fi
log "SELinux after: $(getenforce 2>/dev/null)"
log "=== perf tune done ==="
