#!/system/bin/sh
# ldn20-slim-boot —— restore.sh（一键还原）
#
#   su -c 'sh /data/adb/modules/ldn20-slim-boot/restore.sh'        # 全部还原
#   su -c 'sh /data/adb/modules/ldn20-slim-boot/restore.sh list'   # 看改了啥
#   su -c 'sh /data/adb/modules/ldn20-slim-boot/restore.sh frozen'  # 只解冻应用
#   su -c 'sh /data/adb/modules/ldn20-slim-boot/restore.sh svc'    # 只恢复服务
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失"; exit 1; }

STOPPED=$SLIM_ROOT/boot/stopped_services
FROZEN=$SLIM_ROOT/boot/frozen_packages

show() {
  echo "=== slim-boot 改动清单 ==="
  echo "--- 已停止的 init 服务 ---"
  if [ -s "$STOPPED" ]; then cat "$STOPPED"; else echo "(无)"; fi
  echo "--- 已冻结的包 ---"
  if [ -s "$FROZEN" ]; then cat "$FROZEN"; else echo "(无)"; fi
  echo "备份: $SLIM_ROOT/boot/"
}

# 启动已被 stop 的 init 服务：init 会在下次开机自动拉起，
# 但用户可能想立刻恢复。由于 service 是 oneshot 或由 property 触发，
# 这里用 start 尝试；失败的提示需要重启。
restore_svc() {
  echo "=== 恢复 init 服务 ==="
  if [ ! -s "$STOPPED" ]; then echo "(无记录)"; return 0; fi
  while read -r SVC; do
    [ -z "$SVC" ] && continue
    if start "$SVC" 2>/dev/null; then
      echo "  start $SVC -> $(getprop init.svc.$SVC)"
    else
      echo "  start $SVC 失败：它是 oneshot/受 property 触发，重启手机即自动恢复"
    fi
  done < "$STOPPED"
  echo "提示：init 服务的完整恢复以重启为准。"
}

restore_frozen() {
  echo "=== 解冻应用 ==="
  if [ ! -s "$FROZEN" ]; then echo "(无记录)"; return 0; fi
  while read -r PKG; do
    [ -z "$PKG" ] && continue
    if pm enable "$PKG" >/dev/null 2>&1; then
      echo "  ENABLED $PKG"
    else
      echo "  解冻失败 $PKG"
    fi
  done < "$FROZEN"
}

case "$1" in
  list)   show ;;
  svc)    restore_svc ;;
  frozen) restore_frozen ;;
  *)
    show
    echo
    restore_frozen
    echo
    restore_svc
    echo
    echo "=== 完成。彻底清理：rm -rf /data/adb/ldn20-slim ==="
    ;;
esac
