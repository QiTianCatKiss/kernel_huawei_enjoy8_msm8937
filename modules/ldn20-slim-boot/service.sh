#!/system/bin/sh
# ldn20-slim-boot —— service（late_start：冻结预装后台应用 + 校验）
#
# 冻结用 `pm disable-user --user 0 <pkg>`：
#   - 可逆（`pm enable <pkg>` 即恢复）
#   - 不删文件、不动 /data/app
#   - 冻结后系统不会再给它分配内存、不会拉起进程
#
# 【重要】下面只列「可安全冻结」的包，且每项在执行前会先确认它已安装。
#   系统关键包（launcher / 设置 / 桌面 / 通讯录 / 时钟 / 相机 / 图库 /
#   输入法 / 支付 / 华为基本功能）**一律不在列表里**。
#   你可以在下方 EXTRA_FROZEN 里追加自己的包。
SLIMDIR=/data/adb/ldn20-slim
. "$SLIMDIR/lib/slim_common.sh" 2>/dev/null || { echo "slim_common.sh 缺失，放弃"; exit 0; }

slim_log "--- slim-boot service (late_start) ---"
sleep 35

# ============================================================ 1. 冻结预装应用
# 华为畅享 8 (LDN-AL20) EMUI 8.0 预装里，这批是纯后台/推广性质，
# 冻结后省内存 + 省唤醒，且都能通过 pm enable 恢复。
#
# 【清单依据】包名与存在性来自本机真机 logcat 实测（E:\111\logcat.txt / logcat2.txt，
# 括号内是出现次数），并已剔除全部高风险项：
#   x com.huawei.hwid / .core / com.huawei.hms.account
#       —— HMS 核心 / 华为账号 / 云同步（logcat 95 次），冻结会连锁失败
#   x com.huawei.android.hwouc —— 与 hwid 深度耦合
#   x com.huawei.systemmanager  —— 系统管家，管内存/清理，冻结后后台失控
#   x com.huawei.android.launcher —— 桌面
#   x com.huawei.appmarket      —— EMUI 框架依赖（HwPackageManager 校验）
#   x com.huawei.android.hsf    —— HSF 混合框架，核心 IPC
#   x com.huawei.systemserver   —— 华为系统服务主体
# 格式：包名|说明
BASE_FROZEN="
com.huawei.vassistant|华为语音助手小艺(48)
com.huawei.intelligent|智慧引擎建议推送(39)
com.huawei.android.totemweather|华为天气(24,可换第三方)
com.huawei.recsys|华为推荐/内容推送(19)
com.huawei.himovie|华为视频预装播放器(16)
com.huawei.nlp|华为 NLP 语音服务(12)
com.huawei.gamebox|华为游戏中心(6)
"

# 用户可在此追加自己的包（空格分隔）
EXTRA_FROZEN=""

ALL_FROZEN="$BASE_FROZEN $EXTRA_FROZEN"

FROZEN_LIST="$SLIM_ROOT/boot/frozen_packages"
: > "$FROZEN_LIST" 2>/dev/null

# 注意：这里刻意用 for + 单词切分（列表本身是空格分隔的多行字符串），
# 不走管道 —— Android 的 sh 在管道里 fork 子 shell，计数器会丢。
N=0
for LINE in $ALL_FROZEN; do
  PKG=${LINE%%|*}
  [ -z "$PKG" ] && continue

  # 确认已安装
  if ! pm path "$PKG" >/dev/null 2>&1; then
    slim_log "  跳过 $PKG（本 ROM 未安装）"
    continue
  fi

  # 关键包硬保护：即便误写进列表也拒绝冻结
  case "$PKG" in
    android|com.android.settings|com.android.systemui|com.android.shell|com.android.launcher*|\
    com.android.contacts|com.android.phone|com.android.dialer|com.android.mms|\
    com.android.camera|com.android.gallery*|com.android.externalstorage|\
    com.android.providers.*|com.android.keychain|com.android.location.fused|\
    com.android.server.telecom|com.android.server.*|com.android.certinstaller|\
    com.huawei.android.launcher|com.huawei.systemmanager|com.huawei.hwid|\
    com.huawei.hwid.*|com.huawei.hms.*|com.huawei.android.hwouc|\
    com.huawei.android.hsf|com.huawei.systemserver|com.huawei.appmarket|\
    com.huawei.android.filemanager|com.huawei.android.hidisk|com.huawei.hisuite*)
      slim_log "  保护跳过 $PKG（关键系统包）"
      continue
      ;;
  esac

  if pm disable-user --user 0 "$PKG" >/dev/null 2>&1; then
    echo "$PKG" >> "$FROZEN_LIST" 2>/dev/null
    N=$((N + 1))
    slim_log "  FROZEN $PKG"
  else
    slim_log "  冻结失败 $PKG（已被冻结或无权限）"
  fi
done
slim_log "共冻结 $N 个包（清单: $FROZEN_LIST）"

# ============================================================ 2. 阻止已冻结包被其它组件拉起
# 部分华为组件会通过 broadcast 唤醒被冻结的包；
# setprop 通知 AMS 已冻结是 pm 自身维护的，这里无需额外处理。
# 但可以把"冻结事件"日志级别降下来，减少 logd 压力。
slim_setprop log.tag.PackageManager WARN

# ============================================================ 3. 开机动画后的收尾
# 开机动画播完不等于系统空闲，等 60s 让首轮 dex/资源扫描完成再统计。
sleep 60

# 记录当前内存，供用户对比
{
  echo "=== slim-boot 状态 ==="
  echo "日期        : $(date)"
  echo "--- 已停止服务 ---"
  if [ -s "$SLIM_ROOT/boot/stopped_services" ]; then
    cat "$SLIM_ROOT/boot/stopped_services"
  else
    echo "(无)"
  fi
  echo "--- 已冻结包 ($(grep -c . $FROZEN_LIST 2>/dev/null || echo 0) 个) ---"
  if [ -s "$FROZEN_LIST" ]; then
    cat "$FROZEN_LIST"
  else
    echo "(无)"
  fi
  echo "--- 内存 ---"
  grep -E "MemTotal|MemFree|MemAvailable|Cached|SwapTotal|SwapFree" /proc/meminfo 2>/dev/null
  echo "--- 进程数 ---"
  echo "总进程 : $(ps -A 2>/dev/null | wc -l)"
  echo "运行中 : $(ps -A 2>/dev/null | grep -vE 'zygote|^USER|^ *PID' | wc -l)"
  echo "--- 启动耗时 ---"
  echo "uptime  : $(cat /proc/uptime 2>/dev/null)"
  echo "=========================="
} > /data/local/tmp/slim_boot_status.txt 2>/dev/null

slim_log "状态已写入 /data/local/tmp/slim_boot_status.txt"
slim_log "=== slim-boot service done ==="
