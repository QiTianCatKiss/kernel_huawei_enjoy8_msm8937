#!/system/bin/sh
# LDN-AL20 V10 WiFi 验证脚本（需要 root，可由 KSU adb_root 或 su 执行）
OUT=/data/local/tmp/wifi_v10.txt
: > "$OUT"
L() { echo "$*" >> "$OUT"; }

L "======== V10 WiFi 验证 $(date) ========"
L ""
L "--- 内核版本 ---"
L "$(cat /proc/version)"
L "cmdline: $(cat /proc/cmdline)"
L ""
L "--- 【核心】/proc/wifi_built_in 是否已由内核创建 ---"
if [ -d /proc/wifi_built_in ]; then
  L "OK  /proc/wifi_built_in 存在"
  ls -l /proc/wifi_built_in/ >> "$OUT" 2>&1
else
  L "FAIL /proc/wifi_built_in 不存在 —— V10 内核补丁没生效"
fi
L ""
L "--- 网络接口（/proc/net/dev）---"
L "wlan0 存在: $(grep -q wlan0 /proc/net/dev && echo YES || echo NO)"
cat /proc/net/dev >> "$OUT" 2>&1
L ""
L "--- ip link ---"
ip link show >> "$OUT" 2>&1
L ""
L "--- con_mode / fwpath ---"
L "con_mode = $(cat /sys/module/wlan/parameters/con_mode 2>&1)"
L "fwpath  = $(cat /sys/module/wlan/parameters/fwpath 2>&1)"
L ""
L "--- 属性 ---"
for p in wlan.driver.status init.svc.wpa_supplicant wifi.interface sys.boot_completed \
         wlan.driver.wcnss_service.state; do
  L "$p = [$(getprop $p)]"
done
L ""
L "--- dmesg: wlan 关键行 ---"
dmesg 2>/dev/null | grep -iE 'wlan|hdd|prima|wifi_built_in|cesium|cnss' | tail -60 >> "$OUT" 2>&1
L ""
L "--- dmesg: 内核补丁自检 ---"
dmesg 2>/dev/null | grep -iE 'wifi_built_in|kicked off|kickstart|autostart' | tail -20 >> "$OUT" 2>&1
L ""
L "--- dmesg: KernelSU ---"
dmesg 2>/dev/null | grep -iE 'kernelsu|ksud|suki' | tail -20 >> "$OUT" 2>&1
L ""
L "--- dumpsys wifi 摘要 ---"
dumpsys wifi 2>/dev/null | head -12 >> "$OUT"
L ""
L "--- 性能调参是否生效 ---"
L "io scheduler   = $(cat /sys/block/mmcblk0/queue/scheduler 2>&1)"
L "swappiness     = $(cat /proc/sys/vm/swappiness 2>&1)"
L "readahead      = $(cat /sys/block/mmcblk0/queue/read_ahead_kb 2>&1)"
L ""
L "--- KSU 用户态 ---"
L "/data/adb/ksud        : $(ls -l /data/adb/ksud 2>&1)"
L "/data/adb/modules/    :"
ls -l /data/adb/modules/ >> "$OUT" 2>&1
L ""
L "======== 结束 ========"
echo "OK -> $OUT"
