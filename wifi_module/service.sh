#!/system/bin/sh
# LDN-AL20 WLAN — service 阶段：兜底重试（late_start 之后）
# post-fs-data.sh 已尝试过；这里等 HAL/wcnss 完全就绪后再补一次，并做最终验证。

MODDIR=${0%*}
CON_MODE=/sys/module/wlan/parameters/con_mode
WCN_DEV=/dev/wcnss_wlan

log() { echo "[wlan-fix] $*" > /dev/kmsg 2>/dev/null; }

# 等 wlan0 出现，最多 30s
wait_wlan0() {
  i=0
  while [ $i -lt 30 ]; do
    ip link show wlan0 >/dev/null 2>&1 && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

if wait_wlan0; then
  log "wlan0 present - ok"
  exit 0
fi

log "wlan0 missing, retrying kickstart"

[ -e "$WCN_DEV" ] && : > "$WCN_DEV" 2>/dev/null
[ -e "$CON_MODE" ] || { log "no con_mode node, give up"; exit 0; }

chmod 600 "$CON_MODE" 2>/dev/null
CUR=$(cat "$CON_MODE" 2>/dev/null)
[ "$CUR" = "0" ] && { echo 3 > "$CON_MODE" 2>/dev/null; log "retry kickstart"; }

sleep 5
if wait_wlan0; then
  log "SUCCESS after retry"
else
  log "FAILED - wlan0 still missing"
  dmesg 2>/dev/null | grep -iE 'wlan|hdd|prima' | tail -20 > /dev/kmsg 2>/dev/null
fi

exit 0
