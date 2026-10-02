#!/system/bin/sh
echo "=== full dmesg since kickstart ==="
dmesg | sed -n '/wlan: loading driver/,$p' | tail -120
