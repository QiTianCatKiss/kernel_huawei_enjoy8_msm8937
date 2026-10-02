#!/system/bin/sh
# ldn20-slim-debug —— restore.sh（一键还原）
#
#   su -c 'sh /data/adb/modules/ldn20-slim-debug/restore.sh'       # 全部还原
#   su -c 'sh /data/adb/modules/ldn20-slim-debug/restore.sh list'  # 看改了哪些 prop
#
# 还原策略：
#   log.tag.*     —— 原值为空说明原来是"未设置"，还原就是 setprop 成空
#   其它 prop      —— 一律 setprop "" 恢复默认（这些是 persist/debug 域，
#                     setprop "" 等价于未设置）
#   printk        —— 若备份过则写回
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失"; exit 1; }

PROPBAK=$SLIM_ROOT/debug/props
BAK=$SLIM_ROOT/backup

OTHER_PROPS="
persist.atrace.enabled
persist.sys.atrace.enabled
debug.atrace.force_flush_on_stop
ro.config.hw_appstat
persist.sys.strictmode.disable
persist.sys.logd.hwlog
persist.sys.huawei_debug
persist.sys.userexperience
"

if [ "$1" = "list" ]; then
  echo "=== slim-debug 改动清单 ==="
  echo "--- log.tag（原值 -> 现值）---"
  if [ -s "$PROPBAK" ]; then
    while read -r line; do
      [ -z "$line" ] && continue
      TAG=${line%%=*}; OLD=${line#*=}
      echo "  log.tag.$TAG : '${OLD}' -> '$(getprop log.tag.$TAG)'"
    done < "$PROPBAK"
  else
    echo "(无)"
  fi
  echo "--- 其它 prop ---"
  for P in $OTHER_PROPS; do
    [ -n "$(getprop $P)" ] && echo "  $P = $(getprop $P)"
  done
  exit 0
fi

echo "=== slim-debug 还原 ==="
slim_se_begin

# 1. log.tag
if [ -s "$PROPBAK" ]; then
  while read -r line; do
    [ -z "$line" ] && continue
    TAG=${line%%=*}; OLD=${line#*=}
    if [ -z "$OLD" ]; then
      # 原本未设置 -> 恢复为未设置
      setprop log.tag.$TAG "" 2>/dev/null
      echo "  清除 log.tag.$TAG"
    else
      setprop log.tag.$TAG "$OLD" 2>/dev/null
      echo "  还原 log.tag.$TAG = $OLD"
    fi
  done < "$PROPBAK"
fi

# 2. 其它 prop
for P in $OTHER_PROPS; do
  setprop "$P" "" 2>/dev/null && echo "  清除 $P"
done

# 3. printk
if [ -e "$BAK/kernel.printk" ]; then
  cat "$BAK/kernel.printk" > /proc/sys/kernel/printk 2>/dev/null && \
    echo "  printk 还原为 $(slim_get /proc/sys/kernel/printk)"
fi

slim_se_end
echo "=== 完成。log.tag/printk 需重启手机后完全生效。 ==="
echo "彻底清理：rm -rf /data/adb/ldn20-slim"
