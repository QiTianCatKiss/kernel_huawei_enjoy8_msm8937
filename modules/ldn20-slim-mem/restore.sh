#!/system/bin/sh
# ldn20-slim-mem —— restore.sh（一键还原到原厂值）
#
# 用法：
#   su -c 'sh /data/adb/modules/ldn20-slim-mem/restore.sh'      # 还原全部
#   su -c 'sh /data/adb/modules/ldn20-slim-mem/restore.sh list' # 只看备份了哪些
#
# 原理：post-fs-data / service 每次改参数前都把原值存进
#       /data/adb/ldn20-slim/backup/<tag>，这里按 tag 写回。
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失"; exit 1; }

BAK=$SLIM_ROOT/backup

# tag : 目标文件 : 是否需要 SELinux 放开
LIST="
vm.min_free_kbytes:/proc/sys/vm/min_free_kbytes
vm.swappiness:/proc/sys/vm/swappiness
vm.direct_swappiness:/proc/sys/vm/direct_swappiness
vm.vfs_cache_pressure:/proc/sys/vm/vfs_cache_pressure
vm.dirty_ratio:/proc/sys/vm/dirty_ratio
vm.dirty_background_ratio:/proc/sys/vm/dirty_background_ratio
vm.dirty_expire_centisecs:/proc/sys/vm/dirty_expire_centisecs
vm.dirty_writeback_centisecs:/proc/sys/vm/dirty_writeback_centisecs
vm.laptop_mode:/proc/sys/vm/laptop_mode
vm.oom_kill_allocating_task:/proc/sys/vm/oom_kill_allocating_task
blk.read_ahead_kb:/sys/block/mmcblk0/queue/read_ahead_kb
blk.schedulermmcblk0:/sys/block/mmcblk0/queue/scheduler
blk.schedulermmcblk0rpmb:/sys/block/mmcblk0rpmb/queue/scheduler
zram.comp_algorithm:/sys/block/zram0/comp_algorithm
zram.max_comp_streams:/sys/block/zram0/max_comp_streams
zram.mem_used_max:/sys/block/zram0/mem_used_max
lmk.minfree:/sys/module/lowmemorykiller/parameters/minfree
lmk.cost:/sys/module/lowmemorykiller/parameters/cost
lmk.debug_level:/sys/module/lowmemorykiller/parameters/debug_level
"

if [ "$1" = "list" ]; then
  echo "=== slim-mem 备份清单 ==="
  n=0
  echo "$LIST" | while read -r line; do
    [ -z "$line" ] && continue
    TAG=${line%%:*}; F=${line#*:}
    if [ -e "$BAK/$TAG" ]; then
      printf "  %-32s %s\n" "$TAG" "$(cat $BAK/$TAG 2>/dev/null | tr -d '\r\n')"
    fi
  done
  echo "备份目录: $BAK"
  exit 0
fi

echo "=== slim-mem 还原到原厂值 ==="
slim_se_begin
echo "$LIST" | while read -r line; do
  [ -z "$line" ] && continue
  TAG=${line%%:*}; F=${line#*:}
  if [ -e "$BAK/$TAG" ]; then
    if slim_restore "$TAG" "$F"; then
      echo "  还原 $TAG -> $(slim_get $F | head -c 60)"
    else
      echo "  还原失败 $TAG（目标 $F 不存在？）"
    fi
  fi
done
slim_se_end
echo "=== 完成。若要彻底清理备份，删除 $SLIM_ROOT ==="
