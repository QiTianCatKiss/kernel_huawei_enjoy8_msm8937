#!/system/bin/sh
# LDN-AL20 KernelSU(ReSukiSU) 引导脚本 —— 需要 root
#
# 正常情况下管理器会自动装 ksud；本脚本是兜底（比如管理器版本不匹配时）。
# 前置：/data/local/tmp/ 下已有 libksud.so 与 libadbroot.so
#
# 用法：adb shell su -c 'sh /data/local/tmp/ksu_bootstrap.sh'

LOG=/data/local/tmp/ksu_bootstrap.log
: > "$LOG" 2>/dev/null
log() { echo "$1" >> "$LOG"; }

log "=== ksud 引导开始 ==="

# ---- 1. ksud 主程序 ----
if [ ! -f /data/adb/ksud ]; then
  cp /data/local/tmp/libksud.so /data/adb/ksud && log "已安装 /data/adb/ksud"
else
  log "/data/adb/ksud 已存在"
fi
chmod 0755 /data/adb/ksud
chown 0:0 /data/adb/ksud
log "ksud: $(ls -l /data/adb/ksud)"

# ---- 2. adb_root 支持库（管理器里开启 ADB Root 后 adb shell 直接是 root）----
mkdir -p /data/adb/ksu/lib
cp /data/local/tmp/libadbroot.so /data/adb/ksu/lib/libadbroot.so
chmod 0644 /data/adb/ksu/lib/libadbroot.so
chown 0:0 /data/adb/ksu/lib/libadbroot.so
log "libadbroot.so: $(ls -l /data/adb/ksu/lib/libadbroot.so)"

# ---- 3. 确认性能模块在位（KSU 与 Magisk 共用 /data/adb/modules 格式）----
log "modules 目录:"
ls -l /data/adb/modules/ >> "$LOG" 2>&1

# ---- 4. 输出当前内核侧 KSU 版本，确认与管理器匹配 ----
log "dmesg 中的 KSU 版本行:"
dmesg 2>/dev/null | grep -i "kernelsu" | tail -5 >> "$LOG" 2>&1

log "=== 完成。请重启管理器 App，若仍不可用请把本日志发回 ==="
echo "OK -> $LOG"
