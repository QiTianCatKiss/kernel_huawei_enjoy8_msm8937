#!/system/bin/sh
# ldn20-slim-boot —— post-fs-data（开机早期）
#
# 本阶段做的事：
#   1. 关闭"确定无用"的调试/上报类 init 服务
#   2. 记录本次停用了哪些服务（供还原）
#
# 【安全策略】本机设备当时不在线，服务清单只能部分确认，
# 因此本脚本一律采用「存在才动」：先 getprop 确认 init.svc.<name> 存在且为 running，
# 才 stop。绝不凭空 stop 一个不存在/已被原厂改名的服务。
#
# 不做的事：
#   - 不碰 ueventd / adbd / healthd / console 等基础服务
#   - 不碰 vold / surfaceflinger / zygote* / system_server 依赖链
#   - 不删任何文件
SLIMDIR=/data/adb/ldn20-slim
MYDIR=/data/adb/modules/ldn20-slim-boot
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
slim_log "=== slim-boot post-fs-data start ==="

# ============================================================ 1. 停用调试/上报类服务
#
# 这些是华为 ROM 里典型的"出厂调试/统计"服务，零售机上无实际作用，
# 停止它们可省下可观的后台 CPU 与唤醒次数。
# 每一项都先验证服务确实存在且在运行，才执行 stop。
STOP_LIST="
hw_diag_server
oeminfo_nvm
cust_from_init
libqmi_oem_main
"

STOPPED="$SLIM_ROOT/boot/stopped_services"
: > "$STOPPED" 2>/dev/null

for SVC in $STOP_LIST; do
  ST=$(getprop init.svc.$SVC 2>/dev/null)
  if [ -z "$ST" ]; then
    slim_log "  跳过 $SVC（init.svc.$SVC 不存在，说明本 ROM 无此服务或未启动）"
    continue
  fi
  if [ "$ST" != "running" ]; then
    slim_log "  跳过 $SVC（当前状态 $ST，非 running）"
    continue
  fi
  # 二次保险：黑名单保护，这些绝不能停
  case "$SVC" in
    ueventd|vold|adbd|healthd|console|zygote*|surfaceflinger|netd|media.audio*|audioserver|logd|servicemanager|hwservicemanager)
      slim_log "  拒绝停止受保护服务 $SVC"
      continue
      ;;
  esac
  if stop "$SVC" 2>/dev/null; then
    echo "$SVC" >> "$STOPPED" 2>/dev/null
    slim_log "  STOPPED $SVC"
  else
    slim_log "  stop $SVC 失败（可能被标记 critical，忽略）"
  fi
done

# ============================================================ 2. 降低内核日志量
# printk 的 console_loglevel 影响串口/内核消息输出。
# 本机无串口设备（无任何 UART 驱动），设低只是省一点格式化开销，
# 但更重要的是 logd 的输出等级 —— 见 service.sh。
echo 4 > /proc/sys/kernel/printk 2>/dev/null && slim_log "  printk -> 4 4 1 7"

# kmsg_dump 无关，不动

# ============================================================ 3. 开机阶段 sysprop
# 让部分厂商组件少做点事（都是华为/高通文档里公开的调试开关）
slim_setprop debug.binder.no_callers false
slim_setprop persist.sys.strictmode.disable true
# 关闭 systrace / atrace 的常驻开关（若 ROM 里有这个 prop）
slim_setprop persist.atrace.enabled false
slim_setprop debug.atrace.force_flush_on_stop false

slim_log "=== slim-boot post-fs-data done ==="
