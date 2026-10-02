#!/system/bin/sh
# ldn20-slim-core —— service（late_start：兜底补部署 + 汇总报告）
#
# 场景：用户可能先装了 slim-mem 等模块，后装 core。
# Magisk/KernelSU 各模块的 post-fs-data 顺序不保证，
# 因此这里在 late_start 再检查一次：若公共库仍缺失，
# 扫描已安装的 slim-* 模块目录，把公共库从任何一个完整包里复制过来。
SLIMDIR=/data/adb/ldn20-slim
MYDIR=/data/adb/modules/ldn20-slim-core
MODROOT=/data/adb/modules

LOG=$SLIMDIR/slim.log
log() { echo "[$(date '+%H:%M:%S')] [core] $1" >> "$LOG" 2>/dev/null; }

sleep 20

mkdir -p "$SLIMDIR/lib" 2>/dev/null

# ---- 兜底：若 lib 里缺公共库，从任一已安装的 slim-* 包补齐 ----
NEED_COMMON=0
[ -e "$SLIMDIR/lib/slim_common.sh" ] || NEED_COMMON=1
NEED_STATUS=0
[ -e "$SLIMDIR/slim_status.sh" ] || NEED_STATUS=1

if [ "$NEED_COMMON" = "1" ] || [ "$NEED_STATUS" = "1" ]; then
  log "公共库缺失（common=$NEED_COMMON status=$NEED_STATUS），尝试从已安装模块补齐"
  for D in "$MODROOT"/ldn20-slim-*; do
    [ -d "$D" ] || continue
    if [ "$NEED_COMMON" = "1" ] && [ -e "$D/slim_common.sh" ]; then
      cp -f "$D/slim_common.sh" "$SLIMDIR/lib/" 2>/dev/null \
        && log "  已从 $D 补 slim_common.sh" && NEED_COMMON=0
    fi
    if [ "$NEED_STATUS" = "1" ] && [ -e "$D/slim_status.sh" ]; then
      cp -f "$D/slim_status.sh" "$SLIMDIR/" 2>/dev/null \
        && chmod 755 "$SLIMDIR/slim_status.sh" 2>/dev/null \
        && log "  已从 $D 补 slim_status.sh" && NEED_STATUS=0
    fi
    [ "$NEED_COMMON" = "0" ] && [ "$NEED_STATUS" = "0" ] && break
  done
fi

# ---- 汇总：哪些 slim 模块装了，哪些没装 ----
{
  echo "=== slim 系列安装情况 ==="
  for M in ldn20-slim-core ldn20-slim-mem ldn20-slim-net ldn20-slim-boot ldn20-slim-debug; do
    if [ -d "$MODROOT/$M" ]; then
      # 模块被禁用时目录下会有 disable/ 或 update 标记
      ST="已安装"
      [ -f "$MODROOT/$M/disable" ] && ST="已安装(被禁用)"
      [ -f "$MODROOT/$M/remove" ]  && ST="待删除"
      echo "  [x] $M  $ST"
    else
      echo "  [ ] $M  未安装"
    fi
  done
  echo
  echo "公共库 : $([ -e "$SLIMDIR/lib/slim_common.sh" ] && echo OK || echo 缺失)"
  echo "状态脚本: $([ -e "$SLIMDIR/slim_status.sh" ] && echo OK || echo 缺失)"
  echo
  echo "查看完整状态: sh /data/adb/ldn20-slim/slim_status.sh"
} > /data/local/tmp/slim_install_status.txt 2>/dev/null

log "slim-core service 完成"
