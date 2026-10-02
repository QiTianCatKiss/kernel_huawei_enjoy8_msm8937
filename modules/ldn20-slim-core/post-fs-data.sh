#!/system/bin/sh
# ldn20-slim-core —— post-fs-data（部署公共库）
#
# slim 系列四个模块共用 slim_common.sh 与 slim_status.sh。
# 本模块是唯一携带这两个文件的包，负责在开机早期把它们部署到
# /data/adb/ldn20-slim/ 并建立目录骨架。
#
# 安装顺序：本模块必须先于（或与）其余三个模块安装。
# 四个模块的 post-fs-data.sh 都会做「存在性检查 + 缺失时从本包复制」，
# 所以即使本模块没先装，其余模块也会尝试自行补齐（见各模块脚本）。
SLIMDIR=/data/adb/ldn20-slim
MYDIR=/data/adb/modules/ldn20-slim-core

mkdir -p "$SLIMDIR/lib" "$SLIMDIR/backup" "$SLIMDIR/boot" "$SLIMDIR/debug" 2>/dev/null

LOG=$SLIMDIR/slim.log
log() { echo "[$(date '+%H:%M:%S')] [core] $1" >> "$LOG" 2>/dev/null; }

# 部署公共库（-f 覆盖，保证升级后拿到新版本）
if [ -e "$MYDIR/slim_common.sh" ]; then
  cp -f "$MYDIR/slim_common.sh" "$SLIMDIR/lib/slim_common.sh" 2>/dev/null \
    && log "已部署 slim_common.sh" || log "部署 slim_common.sh 失败"
else
  log "本包内无 slim_common.sh（安装不完整？）"
fi

if [ -e "$MYDIR/slim_status.sh" ]; then
  cp -f "$MYDIR/slim_status.sh" "$SLIMDIR/slim_status.sh" 2>/dev/null \
    && chmod 755 "$SLIMDIR/slim_status.sh" 2>/dev/null \
    && log "已部署 slim_status.sh" || log "部署 slim_status.sh 失败"
else
  log "本包内无 slim_status.sh（安装不完整？）"
fi

log "slim-core 部署完成"
