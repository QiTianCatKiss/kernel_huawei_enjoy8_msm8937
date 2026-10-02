#!/system/bin/sh
# ldn20-slim-mem —— post-fs-data（开机早期）
#
# 本阶段做两件事：
#   1. 尽早把 zram / min_free_kbytes 等"开机就生效才有效"的参数设好
#   2. 记录原厂值供还原
#
# 真正的"最终施加"在 service.sh（late_start），
# 因为华为 init.rc 的 on boot / on property 阶段会把若干值重置。
#
# 全部参数取值依据见本文件末尾的【取值依据】。
SLIMDIR=/data/adb/ldn20-slim
MYDIR=/data/adb/modules/ldn20-slim-mem
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
slim_log "=== slim-mem post-fs-data start ==="

slim_se_begin

# ============================================================ 1. zram
# 原厂 zram 用默认 comp_algorithm（本机 zram 默认 lz4，由 CONFIG_ZRAM_LZ4_COMPRESS=y 决定）
# max_comp_streams 决定并行压缩流数：默认 = 在线 CPU 数。
# 本机 4 颗 A53，默认 4 路并行；但压缩线程与 kswapd 抢 CPU，
# 对 2GB/3GB 小内存机而言 2 路足够，省下的 CPU 能给前台。
for Z in /sys/block/zram0; do
  slim_exists "$Z" || continue
  slim_setnum zram.comp_algorithm "$Z/comp_algorithm" lz4
  slim_setnum zram.max_comp_streams "$Z/max_comp_streams" 2
  # mem_used_max 设为 0 = 不限制，避免 zram 因超限直接返回错误
  slim_setnum zram.mem_used_max "$Z/mem_used_max" 0
done

# ============================================================ 2. min_free_kbytes
# 这是本模块最关键的一项。
# 原理：/proc/sys/vm/min_free_kbytes 是各 zone 的"保留水位"，
# 低于它就触发 kswapd 回收。默认值按内存大小算，非常保守，
# 会让 kswapd 频繁小批量回收 → 每次回收都要扫描页表、压缩 zram，
# 表现为「用一阵就卡一下」。
# 提高它 → 每次回收批量更大、次数更少 → 卡顿更少，
# 代价是可用内存看起来少一点（实际被内核留着做周转）。
# 3GB 机建议 4096~8192 KB，2GB 机建议 2048~4096 KB。
# 这里按实际内存自适应。
MEMTOTAL_KB=0
[ -r /proc/meminfo ] && MEMTOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
[ -z "$MEMTOTAL_KB" ] || [ "$MEMTOTAL_KB" -lt 1 ] 2>/dev/null && MEMTOTAL_KB=0

if [ "$MEMTOTAL_KB" -gt 2500000 ] 2>/dev/null; then
  TARGET_MFK=6144
elif [ "$MEMTOTAL_KB" -gt 1500000 ] 2>/dev/null; then
  TARGET_MFK=4096
else
  TARGET_MFK=3072
fi
CUR_MFK=$(slim_get /proc/sys/vm/min_free_kbytes)
slim_log "MemTotal=${MEMTOTAL_KB}KB  当前 min_free_kbytes=${CUR_MFK} → 目标 ${TARGET_MFK}"
# 持久化给 service.sh（不同进程，变量不会继承）
echo "$TARGET_MFK" > "$SLIM_ROOT/mfk_target" 2>/dev/null
echo "$MEMTOTAL_KB" > "$SLIM_ROOT/memtotal_kb" 2>/dev/null
# 只升不降：原厂若已设得更高就别动
if [ -z "$CUR_MFK" ] || [ "$CUR_MFK" -lt "$TARGET_MFK" ] 2>/dev/null; then
  slim_setnum vm.min_free_kbytes /proc/sys/vm/min_free_kbytes "$TARGET_MFK"
else
  slim_log "  跳过 min_free_kbytes（原厂值已 >= 目标）"
fi

# ============================================================ 3. 华为私有：direct_swappiness
# 【重要】本内核开了 CONFIG_HUAWEI_DIRECT_SWAPPINESS，
# 效果是 vm/swappiness 的取值范围从 0-100 放宽到 0-200，
# 并且**新增**了一个独立节点 vm/direct_swappiness（0-200，注释建议 0-60）。
# 二者分别控制：
#   vm/swappiness         → kswapd 后台回收倾向
#   vm/direct_swappiness  → 分配路径直接回收（direct reclaim）倾向
# 源码（mm/vmscan.c: get_scan_count）：
#     if (current_is_kswapd()) { ... } else { swappiness = direct_vm_swappiness; }
# 即前台进程触发同步回收时用的是 direct_swappiness。
#
# 直接回收发生在用户态已经等不及（内存不够、分配阻塞）时，
# 同步做回收本身就卡；把 direct_swappiness 调低 = 优先换出匿名页而不是做同步扫描，
# 对「点开 app 瞬间卡一下」这类问题有直接改善。
# 0 = 不按 swappiness 换出（只回收 page cache），配合 swappiness=低 效果更稳。
slim_setnum vm.direct_swappiness /proc/sys/vm/direct_swappiness 20

# ============================================================ 4. 脏页回写
# 与 perf_module 原有内容一致（ratio 而非 bytes，避免与内核 bytes 项冲突）
slim_setnum vm.dirty_background_ratio /proc/sys/vm/dirty_background_ratio 5
slim_setnum vm.dirty_ratio             /proc/sys/vm/dirty_ratio             15
slim_setnum vm.dirty_expire_centisecs  /proc/sys/vm/dirty_expire_centisecs  200
slim_setnum vm.dirty_writeback_centisecs /proc/sys/vm/dirty_writeback_centisecs 1500

# ============================================================ 5. swappiness
# 原厂被 init.rc 写成 100（见 service.sh 注释），这里设 70：
# 既保留 zram 的换出收益（后台 app 冷启动更快），
# 又不会像 100 那样在 4 颗 A53 上产生过多压缩/解压开销。
slim_setnum vm.swappiness /proc/sys/vm/swappiness 70

# ============================================================ 6. 缓存保留
# vfs_cache_pressure 默认 100（= 每次 dentry 回收都倾向清缓存）。
# 降到 40~60：保住文件页缓存与 inode 缓存，应用二次启动明显更快。
slim_setnum vm.vfs_cache_pressure /proc/sys/vm/vfs_cache_pressure 50

# ============================================================ 7. 预读
# 闪存随机读代价高，适度加大预读。
# 512KB 对 2GB 内存机偏大（占 0.25%），256KB 是更稳的选择。
slim_setnum blk.read_ahead_kb /sys/block/mmcblk0/queue/read_ahead_kb 256

# ============================================================ 8. I/O 调度器
# V8 内核编译默认已改 deadline，这里做双保险并覆盖所有分区。
for q in /sys/block/mmcblk0/queue /sys/block/mmcblk0rpmb/queue; do
  slim_exists "$q/scheduler" || continue
  if grep -q deadline "$q/scheduler" 2>/dev/null; then
    slim_set "blk.scheduler$(basename $(dirname $q))" "$q/scheduler" deadline
  else
    slim_log "  deadline 不可用于 $q: $(slim_get $q/scheduler)"
  fi
done

# ============================================================ 9. laptop_mode
# laptop_mode=1 会把写回延迟到定时器，理论上省电；
# 但对频繁写库的 app 会造成「写完立刻读」时同步等待，反而更卡。
# 明确关掉。
slim_setnum vm.laptop_mode /proc/sys/vm/laptop_mode 0

# ============================================================ 10. OOM 行为
# oom_kill_allocating_task=1：OOM 时优先杀掉正在分配的进程（即引发 OOM 的那个），
# 避免随机杀一个后台进程导致前台崩。
slim_setnum vm.oom_kill_allocating_task /proc/sys/vm/oom_kill_allocating_task 1

slim_se_end
slim_log "=== slim-mem post-fs-data done ==="
