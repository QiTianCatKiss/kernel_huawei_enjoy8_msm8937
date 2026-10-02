#!/system/bin/sh
# slim_common.sh — LDN-AL20 slim 系列模块公共库
#
# 由 ldn20-slim-mem / -net / -boot / -debug 共用。
# 放在 /data/adb/ldn20-slim/lib/slim_common.sh，
# 各模块用 `. /data/adb/ldn20-slim/lib/slim_common.sh` 引入。
#
# 设计原则：
#   1. 全部改动可逆 —— 改任何参数前先把原值存进备份文件
#   2. 绝不因失败中断开机 —— 所有写操作都带失败容忍
#   3. SELinux 保护 —— 临时 setenforce 0 -> 写入 -> setenforce 1
#      （依赖 V8+ 内核的 CONFIG_SECURITY_SELINUX_DEVELOP）
#   4. 幂等 —— 重复执行结果一致

SLIM_ROOT=/data/adb/ldn20-slim
SLIM_LIB=$SLIM_ROOT/lib
SLIM_BAK=$SLIM_ROOT/backup
SLIM_LOG=$SLIM_ROOT/slim.log

# 日志上限，避免无限增长
SLIM_LOG_MAX=256

slim_ts() { date '+%m-%d %H:%M:%S'; }

slim_log() {
  # 写入日志；日志超过上限时清空重来，避免占满 /data
  if [ -f "$SLIM_LOG" ]; then
    SZ=$(wc -c < "$SLIM_LOG" 2>/dev/null || echo 0)
    [ "${SZ:-0}" -gt 16384 ] && : > "$SLIM_LOG" 2>/dev/null
  fi
  echo "[$(slim_ts)] $1" >> "$SLIM_LOG" 2>/dev/null
}

slim_init() {
  mkdir -p "$SLIM_BAK" 2>/dev/null
}

# ---------------------------------------------------------------- SELinux
# slim_selenforce_begin: 若当前是 Enforcing 则临时关闭，返回 1 表示"需要恢复"
SLIM_SE_DISABLED=0
slim_se_begin() {
  SLIM_SE_DISABLED=0
  ENF=$(getenforce 2>/dev/null)
  if [ "$ENF" = "Enforcing" ]; then
    if setenforce 0 2>/dev/null; then
      SLIM_SE_DISABLED=1
      slim_log "SELinux Enforcing -> Permissive"
    else
      slim_log "setenforce 0 FAILED（内核未开 SELINUX_DEVELOP？）后续写入可能被拒"
    fi
  fi
}

slim_se_end() {
  if [ "$SLIM_SE_DISABLED" = "1" ]; then
    i=0
    while [ $i -lt 5 ]; do
      setenforce 1 2>/dev/null
      if getenforce 2>/dev/null | grep -q Enforcing; then
        slim_log "SELinux 恢复 Enforcing"
        SLIM_SE_DISABLED=0
        return 0
      fi
      i=$((i + 1))
      sleep 2
    done
    slim_log "警告：SELinux 未能恢复 Enforcing！请手动 setenforce 1"
  fi
}

# ---------------------------------------------------------------- 备份/还原
# slim_bak <tag> <文件路径>
#   把 <文件路径> 当前内容存到 $SLIM_BAK/<tag>（只存第一次）
slim_bak() {
  TAG=$1
  F=$2
  [ -e "$F" ] || return 1
  if [ ! -e "$SLIM_BAK/$TAG" ]; then
    cat "$F" > "$SLIM_BAK/$TAG" 2>/dev/null && return 0
  fi
  return 0
}

# slim_restore <tag> <文件路径>
#   用备份覆盖回原值（还原用）
slim_restore() {
  TAG=$1
  F=$2
  if [ -e "$SLIM_BAK/$TAG" ]; then
    cat "$SLIM_BAK/$TAG" > "$F" 2>/dev/null && return 0
  fi
  return 1
}

# slim_has_bak <tag>
slim_has_bak() { [ -e "$SLIM_BAK/$1" ]; }

# ---------------------------------------------------------------- 写入封装
# slim_set <tag> <文件路径> <值>
#   备份原值 -> 写入新值 -> 记录结果
slim_set() {
  TAG=$1
  F=$2
  VAL=$3
  slim_bak "$TAG" "$F" || return 1
  if echo "$VAL" > "$F" 2>/dev/null; then
    slim_log "  SET $TAG = $VAL"
    return 0
  else
    slim_log "  FAIL $TAG（写不进去，可能被 SELinux 拒或节点只读）"
    return 1
  fi
}

# slim_setnum <tag> <文件路径> <值>  —— 同 slim_set，但会校验读回值
slim_setnum() {
  TAG=$1
  F=$2
  VAL=$3
  slim_bak "$TAG" "$F" || return 1
  if echo "$VAL" > "$F" 2>/dev/null; then
    GOT=$(cat "$F" 2>/dev/null | tr -d '\r\n ')
    if [ "$GOT" = "$VAL" ]; then
      slim_log "  OK  $TAG = $GOT"
      return 0
    else
      slim_log "  WARN $TAG 期望 $VAL 实际 $GOT（可能被华为 init.rc 覆盖）"
      return 1
    fi
  fi
  slim_log "  FAIL $TAG（写入失败）"
  return 1
}

# slim_get <文件路径> —— 安全读取
slim_get() {
  [ -e "$1" ] && cat "$1" 2>/dev/null | tr -d '\r'
}

# slim_exists <路径>
slim_exists() { [ -e "$1" ]; }

# ---------------------------------------------------------------- 运行时属性
# slim_setprop <名称> <值>
slim_setprop() {
  if setprop "$1" "$2" 2>/dev/null; then
    slim_log "  setprop $1 = $2"
  else
    slim_log "  setprop $1 FAILED"
  fi
}

# ---------------------------------------------------------------- 冻结应用
# slim_freeze <包名...>
#   用 pm disable-user 冻结（可逆：enable 包名即恢复）
#   注意：只冻结用户已确认的后台预装，系统关键包不在此列
slim_freeze() {
  for PKG in "$@"; do
    [ -z "$PKG" ] && continue
    if pm disable-user --user 0 "$PKG" >/dev/null 2>&1; then
      slim_log "  FROZEN $PKG"
    else
      slim_log "  freeze skip $PKG（未安装/已冻结/无权限）"
    fi
  done
}

# slim_unfreeze <包名...>
slim_unfreeze() {
  for PKG in "$@"; do
    [ -z "$PKG" ] && continue
    pm enable "$PKG" >/dev/null 2>&1 && slim_log "  UNFROZEN $PKG"
  done
}
