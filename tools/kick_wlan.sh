#!/system/bin/sh
# 尝试放行 sysfs 写入，然后 kickstart wlan 驱动
echo "=== before ==="
ls -l /sys/module/wlan/parameters/con_mode

echo "=== try chmod 600 ==="
chmod 600 /sys/module/wlan/parameters/con_mode 2>&1
ls -l /sys/module/wlan/parameters/con_mode

echo "=== try write con_mode=3 ==="
echo 3 > /sys/module/wlan/parameters/con_mode 2>&1
echo "write rc=$?"

sleep 6
echo "=== link ==="
ip link show wlan0 2>&1
echo "=== dmesg tail ==="
dmesg | grep -iE 'wlan|hdd|prima|wcnss|con_mode|kickstart' | tail -25
