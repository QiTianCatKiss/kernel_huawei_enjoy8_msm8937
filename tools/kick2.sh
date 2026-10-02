#!/system/bin/sh
# 打开 prima 详细日志再重启驱动
P=/sys/module/wlan/parameters
echo "=== enable driver logs via con_mode (0 -> 3) ==="
echo 0 > $P/con_mode; sleep 3
echo "stopped rc=$?"
echo 3 > $P/con_mode; sleep 8
echo "start rc=$?"
echo "=== link ==="
ip link show wlan0 2>&1
echo
echo "=== dmesg wlan/hdd/vos lines ==="
dmesg | grep -iE 'wlan|hdd|voss|vos_|prima|cfg80211|supplicant|regulatory|channel|firmware' | tail -60
