#!/system/bin/sh
# ldn20-slim-debug —— post-fs-data（压低日志等级）
#
# 【本机内核实际配置】stock config 里：
#   CONFIG_HW_LOGGER=y           华为日志扩展驱动
#   CONFIG_LOGGER_EXTEND=y
#   CONFIG_ANDROID_LOGGER 未开
#   CONFIG_CNSS_LOGGER 未开
# 驱动接口（源码 drivers/staging/android/hwlogger/）：
#   hw_logger.c        用 hwlog_tag 段记录，无 module_param，无 /proc 节点
#   hw_reboot_wdt.c    建 /proc/reboot_watchdog (0200，仅写)
#
# 【重要】/proc/reboot_watchdog **不是**检测上报，是重启通知机制：
#   华为用户在关机时把自身 pid 写进去，内核在 reboot 时给这些 pid 发信号，
#   让它们有机会清理挂载点（否则可能丢数据/下次开机异常）。
#   本模块**不动它**。
#
# 能压的只有 logd 侧（用户态 setprop log.tag.*）与 printk 等级。
SLIMDIR=/data/adb/ldn20-slim
MYDIR=/data/adb/modules/ldn20-slim-debug
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
slim_log "=== slim-debug post-fs-data start ==="

slim_se_begin

# ============================================================ 1. logd 分类日志等级
# logd 的分类等级由系统属性 log.tag.<TAG> 控制，取值：
#   V D I W E S(静默) F(不记) ... 以及 0-7 数字（越大越详细）
# setprop log.tag.<TAG> S = 该 TAG 只打 error 以上
# setprop log.tag.<TAG> "" / F = 完全不记
#
# 下面是本机 logcat 里实测「刷屏最凶」且对用户无价值的 TAG。
# 每项都会先备份原值（logd 的属性存在 /data/system 下，本模块用单独文件记录）。
PROPBAK=$SLIM_ROOT/debug/props
: > "$PROPBAK" 2>/dev/null

set_logtag() {
  TAG=$1
  LEVEL=$2
  CUR=$(getprop log.tag.$TAG 2>/dev/null)
  echo "$TAG=$CUR" >> "$PROPBAK" 2>/dev/null
  # 只在未设置过时才设，避免覆盖用户自定义
  if [ -z "$CUR" ]; then
    setprop log.tag.$TAG "$LEVEL" 2>/dev/null && slim_log "  log.tag.$TAG = $LEVEL"
  else
    slim_log "  跳过 log.tag.$TAG（已有值 $CUR）"
  fi
}

# 华为 ROM 里高频打印的组件
set_logtag HwPackageManagerService S
set_logtag HwNetworkManagementService S
set_logtag HwBinderProxy   S
set_logtag CertCompatSettings S
set_logtag VoldConnector   S
set_logtag VoldCmdListener S
set_logtag HwMountService  S
set_logtag HwServicemanagerProvider S
set_logtag HwIccHelper     S
set_logtag HwActivityManager S
set_logtag HwWindowManager S
set_logtag IQManager       S
set_logtag data          W
set_logtag SurfaceFlinger W
# WiFi 驱动在正常使用时是纯噪声
set_logtag wlan0         S
set_logtag cnss          S
set_logtag wcnss         S
set_logtag prima         S
set_logtag ioctl         S
set_logtag tsched        S
set_logtag timer         S

# ============================================================ 2. atrace / systrace
# 关闭常驻 tracing 开关（开发者选项里手动开 systrace 时会再打开）
slim_setprop persist.atrace.enabled false
slim_setprop persist.sys.atrace.enabled false
slim_setprop debug.atrace.force_flush_on_stop false
slim_setprop ro.config.hw_appstat false

# ============================================================ 3. StrictMode
# StrictMode 在 release 版不该生效，但厂商 ROM 常忘记关，
# 每次主线程磁盘访问都会打 log 并可能触发 ANR 弹窗。
slim_setprop persist.sys.strictmode.disable true

# ============================================================ 4. printk
# 第一列是当前 console 输出等级（写不进去，只影响 /dev/kmsg 读取端）
# 本机无串口设备，纯粹是降噪
slim_setnum kernel.printk /proc/sys/kernel/printk "4 4 1 7"

# dmesg_restrict=1：非 root 不能读 dmesg（内核 3.18 支持，安全性）
# 注意：这会让 adb shell 也读不了 dmesg —— 调试时不便。
# 因此**默认不改**，只记录，由用户决定。
# slim_setnum kernel.dmesg_restrict /proc/sys/kernel/dmesg_restrict 1
slim_log "dmesg_restrict 保持原状（保持可读，便于排障）"

# ============================================================ 5. 华为统计上报属性
# 【仅限明确是"统计/诊断"的开关，逐个谨慎设置】
# 注意：ro.* 是只读属性，setprop 会失败（slim_setprop 会记录 FAILED），属正常。
# persist.sys.logd 之类若不存在也不影响开机。
slim_setprop persist.sys.logd.hwlog false

# 华为工程模式开关（售后调试用）
slim_setprop persist.sys.huawei_debug false

# 关闭 EMUI 的"用户体验改进计划"（若存在此属性）
slim_setprop persist.sys.userexperience false

slim_se_end
slim_log "=== slim-debug post-fs-data done ==="
