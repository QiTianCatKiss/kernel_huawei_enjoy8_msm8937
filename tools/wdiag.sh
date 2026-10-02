#!/system/bin/sh
# LDN-AL20 WiFi 诊断（V9 / ReSukiSU）
OUT=/data/local/tmp/wdiag.txt
: > "$OUT"
L() { echo "$*" >> "$OUT"; }

L "======== WiFi 诊断 $(date) ========"
L ""
L "--- 内核 ---"
L "uname: $(uname -a)"
L "cmdline: $(cat /proc/cmdline)"
L ""
L "--- wlan 相关属性 ---"
for p in wlan.driver.status wlan.driver.ath init.svc.wpa_supplicant init.svc.wificond init.svc.cnss-daemon \
         vendor.wlan.driver.version wifi.interface sys.boot_completed ro.bootmode; do
  L "$p = [$(getprop "$p")]"
done
L ""
L "--- 网络接口 ---"
ip link show >> "$OUT" 2>&1
L ""
L "--- con_mode / wcnss 节点 ---"
L "con_mode exists: $([ -e /sys/module/wlan/parameters/con_mode ] && echo YES || echo NO)"
L "con_mode value : $(cat /sys/module/wlan/parameters/con_mode 2>&1)"
L "con_mode perm  : $(ls -l /sys/module/wlan/parameters/con_mode 2>&1)"
L "wcnss_wlan dev : $(ls -l /dev/wcnss_wlan 2>&1)"
L ""
L "--- wlan 模块目录 ---"
ls -l /sys/module/wlan/ 2>&1 | head -20 >> "$OUT"
L ""
L "--- 已加载含 wlan/prima 的模块 ---"
lsmod 2>/dev/null | grep -iE 'wlan|prima|cnss|wcnss' >> "$OUT" 2>&1
L ""
L "--- firmware 相关 ---"
ls -l /vendor/firmware/ 2>&1 | grep -iE 'wlan|wcnss|prima' >> "$OUT"
ls -l /system/etc/firmware/ 2>&1 | grep -iE 'wlan|wcnss|prima' >> "$OUT"
L ""
L "--- Magisk / KSU 模块 ---"
L "modules dir:"
ls -l /data/adb/modules/ >> "$OUT" 2>&1
L ""
L "--- KernelSU ---"
L "/dev/ksu: $(ls -l /dev/ksu 2>&1)"
L "ksu vers : $(cat /sys/kernel/ksu/version 2>&1)"
L ""
L "--- dmesg: wlan/hdd/prima/cesium ---"
dmesg 2>/dev/null | grep -iE 'wlan|hdd|prima|cesium|cnss|wcnss|netlink|nl_sock' | tail -80 >> "$OUT"
L ""
L "--- dmesg: KernelSU / ksud ---"
dmesg 2>/dev/null | grep -iE 'kernelsu|ksu|ksud|suki' | tail -30 >> "$OUT"
L ""
L "--- dmesg: 最后 40 行 ---"
dmesg 2>/dev/null | tail -40 >> "$OUT"
L ""
L "--- wlan-fix 模块日志（kmsg） ---"
dmesg 2>/dev/null | grep -iE 'wlan-fix' | tail -20 >> "$OUT"
L ""
L "======== 结束 ========"
echo done
