#!/system/bin/sh
# LDN-AL20 WLAN — post-fs-data 阶段：尽早把 built-in wlan 驱动 kickstart 起来
#
# 背景（已真机验证，2026-10-02）：
#   - wlan 驱动是 built-in 在内核里的（CONFIG_PRONTO_WLAN=y → drivers/Makefile:185 → drivers/prima/），
#     不需要也不能 insmod。
#   - 原厂靠 /vendor/bin/wifi_driver_init 写 /proc/wifi_built_in/wifi_start 启动驱动，
#     但该 proc 节点是华为私有下游代码，发布源码树里完全没有。
#   - 等价替代：写 /sys/module/wlan/parameters/con_mode
#     → wlan_hdd_main.c 的 con_mode_handler → kickstart_driver() → hdd_driver_init()
#     与原厂 wifi_start 节点背后是同一套逻辑。
#   - con_mode 节点默认 0644（root 只读），需先 chmod 600。
#   - 内核侧已修：cesium nl_sock 失败不再致命（否则驱动 init 整体回滚）。

MODDIR=${0%/*}
CON_MODE=/sys/module/wlan/parameters/con_mode
WCN_DEV=/dev/wcnss_wlan

log() { echo "[wlan-fix] $*" > /dev/kmsg 2>/dev/null; }

# 1) WCN 上电（wcnss 平台驱动）—— 驱动 init 前必须
[ -e "$WCN_DEV" ] && : > "$WCN_DEV" 2>/dev/null

# 2) 内核里没有 wlan 驱动就放弃（编译问题，不是本模块能修的）
[ -e "$CON_MODE" ] || { log "no con_mode node - wlan driver not built-in"; exit 0; }

# 3) 已经在跑就不动（幂等）
CUR=$(cat "$CON_MODE" 2>/dev/null)
[ "$CUR" != "0" ] && { log "already started (con_mode=$CUR)"; exit 0; }

# 4) 放开写权限并 kickstart
chmod 600 "$CON_MODE" 2>/dev/null
echo 3 > "$CON_MODE" 2>/dev/null && log "kickstart con_mode=3 issued"

exit 0
