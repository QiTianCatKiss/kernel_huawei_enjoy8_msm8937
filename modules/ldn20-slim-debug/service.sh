#!/system/bin/sh
# ldn20-slim-debug —— service（late_start：清理日志缓冲 + 状态输出）
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失，放弃"; exit 0; }

slim_log "--- slim-debug service (late_start) ---"
sleep 40

slim_se_begin

# ============================================================ 1. 历史日志清理
# 只删"确定的日志文件"，不碰 logd 的活动 fd，不删用户数据。
LOGDMP=/data/log
if [ -d "$LOGDMP" ]; then
  # 只删超过 1 天的系统日志（boot_log/ crash 之类），保留最近一天便于回溯
  find "$LOGDMP" -type f -mtime +1 2>/dev/null | while read -r f; do
    SZ=$(stat -c %s "$f" 2>/dev/null || echo 0)
    slim_log "  删除旧日志 $f ($SZ bytes)"
    rm -f "$f" 2>/dev/null
  done
fi

# logcat 环形缓冲大小：默认可能几百 MB。压到 512K 省 /data 空间。
# /data/system/log 路径在 Android 8 是 /data/misc/logd/
for B in 256 512 1024; do
  D=/data/misc/logd/logcat-$B
  if [ -d "$D" ]; then
    slim_log "  logcat 缓冲 $D: $(ls $D 2>/dev/null | wc -l) 个文件"
  fi
done

# 清理其他常见落盘日志
for F in /data/vendor/log/AGENTDEBUG.log \
         /data/vendor/log/xtc_route.log \
         /data/misc/logd/boot_log \
         /data/misc/logd/main_log \
         /data/misc/logd/system_log \
         /data/misc/logd/radio_log \
         /data/misc/logd/events_log \
         /data/misc/logd/crash_log; do
  if [ -f "$F" ]; then
    SZ=$(stat -c %s "$F" 2>/dev/null || echo 0)
    [ "$SZ" -gt 1048576 ] 2>/dev/null && { : > "$F" 2>/dev/null && slim_log "  清空 $F ($SZ bytes)"; }
  fi
done

# ============================================================ 2. 保留 reboot_watchdog 说明
# /proc/reboot_watchdog 由用户态（华为关机流程）写入 pid，
# 内核 reboot 时给它们发信号做清理。**不清理、不破坏**。
if [ -e /proc/reboot_watchdog ]; then
  slim_log "/proc/reboot_watchdog 存在（保持不动，重启通知机制）"
else
  slim_log "/proc/reboot_watchdog 不存在（内核未编 hw_reboot_wdt？）"
fi

# ============================================================ 3. 复核 logtag 生效
# logd 会在 property change 后重读，但某些 TAG 需重启才完全生效。
N=0
while read -r line; do
  [ -z "$line" ] && continue
  TAG=${line%%=*}
  N=$((N + 1))
done < "$SLIM_ROOT/debug/props" 2>/dev/null
slim_log "已配置 log.tag 共 $N 项"

slim_se_end

# ============================================================ 状态输出
DUMP=/data/local/tmp/slim_debug_status.txt
{
  echo "=== LDN-AL20 slim-debug 生效值 ==="
  echo "日期        : $(date)"
  echo "--- printk ---"
  echo "printk      : $(slim_get /proc/sys/kernel/printk)"
  echo "dmesg_restr : $(slim_get /proc/sys/kernel/dmesg_restrict)"
  echo "--- log.tag 生效值 ---"
  while read -r line; do
    [ -z "$line" ] && continue
    TAG=${line%%=*}
    echo "  $TAG = $(getprop log.tag.$TAG)"
  done < "$SLIM_ROOT/debug/props" 2>/dev/null
  echo "--- 关键 prop ---"
  for P in persist.atrace.enabled debug.atrace.force_flush_on_stop \
           persist.sys.strictmode.disable ro.config.hw_appstat \
           persist.sys.userexperience persist.sys.huawei_debug; do
    echo "  $P = $(getprop $P)"
  done
  echo "--- 硬件日志 ---"
  if [ -e /proc/reboot_watchdog ]; then
    echo "reboot_wdt  : 存在（保持不动，重启通知机制）"
  else
    echo "reboot_wdt  : 不存在（内核未编 hw_reboot_wdt？）"
  fi
  echo "--- 落盘日志 ---"
  du -sh /data/misc/logd 2>/dev/null | sed 's/^/  logd: /'
  du -sh /data/vendor/log 2>/dev/null | sed 's/^/  vendor: /'
  echo "=========================="
} > "$DUMP" 2>/dev/null

slim_log "状态已写入 $DUMP"
slim_log "=== slim-debug service done ==="
