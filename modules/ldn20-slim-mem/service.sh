#!/system/bin/sh
# ldn20-slim-mem —— service（late_start 阶段：重新施加 + 对抗重置 + 校验）
#
# 为什么必须在这里再施加一遍：
#   华为 /vendor/etc/init/hw/init.target.rc 里有多处
#     "on boot" / "on property:sys.boot_completed=1"
#     write /proc/sys/vm/swappiness 100
#   其触发时机会**晚于** post-fs-data，把早期写入的值覆盖掉。
#   所以真正的生效点在开机流程基本结束时（late_start）。
#
# 华为还会重置 read_ahead_kb=128 等，因此本脚本在
#   +25s（等系统稳定）
#   +90s（覆盖 on property:sys.boot_completed 触发的重置）
#   +240s（兜底）
# 各补写一次，但只在"值真的被改回去了"时才写，避免无谓的 I/O。
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失，放弃"; exit 0; }

slim_log "--- slim-mem service (late_start) ---"

sleep 25

slim_se_begin

# ============================================================ LMKD 阈值
# 【本机内核实际接口】drivers/staging/android/lowmemorykiller.c
#   CONFIG_ANDROID_LOW_MEMORY_KILLER=y（built-in）
#   参数以 module_param 暴露，built-in 下位于：
#     /sys/module/lowmemorykiller/parameters/<name>
#
#   默认值（源码 lowmemorykiller.c:79-87）：
#     minfree = { 3*512, 2*1024, 4*1024, 16*1024 } 页
#             = { 6MB, 8MB, 16MB, 64MB }   ← 4 档，对应 adj 档位
#     adj    = { 0, 1, 6, 12 }
#     adj_max_shift = 353
#     cost (seeks) = 模块内初值
#     lmk_fast_run = 1
#     debug_level = 1
#
#   语义：free 内存低于第 N 档 minfree 时，杀掉 oom_score_adj >= 第 N 档 adj 的进程。
#        档位越往后越宽松（杀更不重要、adj 更大的进程）。
#
#   原厂这套值对 2GB/3GB 小内存机偏激进 —— 6MB 就开始杀，
#   后台 app 被反复杀掉重启，吃 CPU 又耗电。
#   下面把前两档抬高，让 LMKD 更晚介入、且优先杀可重建的后台缓存进程，
#   给前台留出余量。**不改 adj 本身**（那是 oom_score_adj 阈值，改动风险高）。
LMK=/sys/module/lowmemorykiller/parameters
if [ -d "$LMK" ]; then
  slim_log "LMKD 参数目录: $LMK"
  # minfree 数组：4 档，单位为页（4KB）
  # 原厂 1536 / 2048 / 4096 / 16384
  # 调整 3072 / 4096 / 8192 / 20480  （即 12MB/16MB/32MB/80MB）
  # 效果：低档抬高 → 不再频繁杀；高档略抬 → 极端压力下仍保留杀高档进程的能力
  slim_setnum lmk.minfree "$LMK/minfree" "3072,4096,8192,20480"
  # 杀进程的成本：值越大越"舍不得杀"（扫描更贵则跳过本轮）
  slim_setnum lmk.cost "$LMK/cost" 10
  # 关掉 LMKD 的调试打印（默认 1 会打 pr_info）
  slim_setnum lmk.debug_level "$LMK/debug_level" 0
  # lmk_fast_run：快速连续跑（默认 1）。保持 1，不动。
  # enable_adaptive_lmk：基于 vmpressure 动态调整，默认关闭，保持原样。
  # adj_max_shift：默认 353，保持（改它会影响系统对自身进程的 adj 计算）。
else
  slim_log "未找到 $LMK（非本项目内核？）跳过 LMKD 调整"
fi

# ============================================================ 重新施加内核参数
apply() {
  # zram
  for Z in /sys/block/zram0; do
    [ -e "$Z" ] || continue
    [ "$(slim_get $Z/max_comp_streams)" != "2" ] && \
      slim_setnum zram.max_comp_streams "$Z/max_comp_streams" 2
  done

  # 华为私有 direct_swappiness
  [ "$(slim_get /proc/sys/vm/direct_swappiness)" != "20" ] && \
    slim_setnum vm.direct_swappiness /proc/sys/vm/direct_swappiness 20

  # 脏页
  [ "$(slim_get /proc/sys/vm/dirty_background_ratio)" != "5" ] && \
    slim_setnum vm.dirty_background_ratio /proc/sys/vm/dirty_background_ratio 5
  [ "$(slim_get /proc/sys/vm/dirty_ratio)" != "15" ] && \
    slim_setnum vm.dirty_ratio /proc/sys/vm/dirty_ratio 15
  [ "$(slim_get /proc/sys/vm/dirty_expire_centisecs)" != "200" ] && \
    slim_setnum vm.dirty_expire_centisecs /proc/sys/vm/dirty_expire_centisecs 200
  [ "$(slim_get /proc/sys/vm/dirty_writeback_centisecs)" != "1500" ] && \
    slim_setnum vm.dirty_writeback_centisecs /proc/sys/vm/dirty_writeback_centisecs 1500

  # swappiness / 缓存
  [ "$(slim_get /proc/sys/vm/swappiness)" != "70" ] && \
    slim_setnum vm.swappiness /proc/sys/vm/swappiness 70
  [ "$(slim_get /proc/sys/vm/vfs_cache_pressure)" != "50" ] && \
    slim_setnum vm.vfs_cache_pressure /proc/sys/vm/vfs_cache_pressure 50

  # 预读（原厂 init.rc 会写回 128）
  [ "$(slim_get /sys/block/mmcblk0/queue/read_ahead_kb)" != "256" ] && \
    slim_setnum blk.read_ahead_kb /sys/block/mmcblk0/queue/read_ahead_kb 256

  # I/O 调度器
  for q in /sys/block/mmcblk0/queue /sys/block/mmcblk0rpmb/queue; do
    [ -e "$q/scheduler" ] && grep -q deadline "$q/scheduler" 2>/dev/null && \
      [ "$(slim_get $q/scheduler)" != "[deadline]" ] && \
      slim_set "blk.scheduler$(basename $(dirname $q))" "$q/scheduler" deadline
  done

  # laptop_mode / OOM
  [ "$(slim_get /proc/sys/vm/laptop_mode)" != "0" ] && \
    slim_setnum vm.laptop_mode /proc/sys/vm/laptop_mode 0
  [ "$(slim_get /proc/sys/vm/oom_kill_allocating_task)" != "1" ] && \
    slim_setnum vm.oom_kill_allocating_task /proc/sys/vm/oom_kill_allocating_task 1

  # min_free_kbytes（目标值由 post-fs-data 持久化，这里读回）
  MFK=$(slim_get /proc/sys/vm/min_free_kbytes)
  TARGET_MFK=$(slim_get "$SLIM_ROOT/mfk_target")
  if [ -n "$TARGET_MFK" ] && [ -n "$MFK" ] && [ "$MFK" -lt "$TARGET_MFK" ] 2>/dev/null; then
    slim_setnum vm.min_free_kbytes /proc/sys/vm/min_free_kbytes "$TARGET_MFK"
  fi
}

apply
slim_log "首次施加完成"

# ============================================================ 对抗重置
# 后台循环：只在检测到被改回时才重写
(
  for WAIT in 65 150 240; do
    sleep $WAIT
    getenforce 2>/dev/null | grep -q Enforcing && setenforce 0 2>/dev/null
    NEED=0
    for CHK in /proc/sys/vm/swappiness:70 \
               /proc/sys/vm/direct_swappiness:20 \
               /proc/sys/vm/dirty_ratio:15 \
               /proc/sys/vm/vfs_cache_pressure:50 \
               /sys/block/mmcblk0/queue/read_ahead_kb:256; do
      P=${CHK%%:*}; WANT=${CHK##*:}
      [ -e "$P" ] || continue
      GOT=$(slim_get "$P")
      [ "$GOT" = "$WANT" ] || NEED=1
    done
    if [ "$NEED" = "1" ]; then
      slim_log "+${WAIT}s 检测到参数被重置，重新施加"
      apply
    else
      slim_log "+${WAIT}s 复核：全部参数保持"
    fi
    getenforce 2>/dev/null | grep -q Permissive && setenforce 1 2>/dev/null
  done
) &

slim_se_end

# ============================================================ 状态输出
DUMP=/data/local/tmp/slim_mem_status.txt
{
  echo "=== LDN-AL20 slim-mem 生效值 ==="
  echo "日期            : $(date)"
  echo "SELinux         : $(getenforce 2>/dev/null)"
  echo "MemTotal        : $(awk '/MemTotal/{print $2" kB"}' /proc/meminfo 2>/dev/null)"
  echo "--- 内存回收 ---"
  echo "min_free_kbytes : $(slim_get /proc/sys/vm/min_free_kbytes)"
  echo "swappiness      : $(slim_get /proc/sys/vm/swappiness)"
  echo "direct_swappiness: $(slim_get /proc/sys/vm/direct_swappiness)"
  echo "vfs_cache_press : $(slim_get /proc/sys/vm/vfs_cache_pressure)"
  echo "laptop_mode     : $(slim_get /proc/sys/vm/laptop_mode)"
  echo "oom_kill_alloc  : $(slim_get /proc/sys/vm/oom_kill_allocating_task)"
  echo "--- 脏页 ---"
  echo "dirty_ratio     : $(slim_get /proc/sys/vm/dirty_ratio)"
  echo "dirty_bg_ratio  : $(slim_get /proc/sys/vm/dirty_background_ratio)"
  echo "dirty_expire_cs : $(slim_get /proc/sys/vm/dirty_expire_centisecs)"
  echo "dirty_wb_cs     : $(slim_get /proc/sys/vm/dirty_writeback_centisecs)"
  echo "--- 存储 ---"
  echo "scheduler       : $(slim_get /sys/block/mmcblk0/queue/scheduler)"
  echo "read_ahead_kb   : $(slim_get /sys/block/mmcblk0/queue/read_ahead_kb)"
  echo "--- zram ---"
  echo "disksize        : $(slim_get /sys/block/zram0/disksize)"
  echo "comp_algorithm  : $(slim_get /sys/block/zram0/comp_algorithm)"
  echo "max_comp_streams: $(slim_get /sys/block/zram0/max_comp_streams)"
  echo "mem_used_total  : $(slim_get /sys/block/zram0/mem_used_total)"
  echo "orig_data_size  : $(slim_get /sys/block/zram0/orig_data_size)"
  echo "--- LMKD ---"
  echo "minfree         : $(slim_get $LMK/minfree)"
  echo "adj             : $(slim_get $LMK/adj)"
  echo "cost            : $(slim_get $LMK/cost)"
  echo "debug_level     : $(slim_get $LMK/debug_level)"
  echo "lmk_fast_run    : $(slim_get $LMK/lmk_fast_run)"
  echo "--- 调频 ---"
  echo "governor        : $(slim_get /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  echo "cpu_online      : $(cat /sys/devices/system/cpu/online 2>/dev/null)"
  echo "=========================="
} > "$DUMP" 2>/dev/null

slim_log "状态已写入 $DUMP"
slim_log "=== slim-mem service done ==="
