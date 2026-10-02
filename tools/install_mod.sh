#!/system/bin/sh
MODDIR=/data/adb/modules/ldnal20-wlan
ZIP=/sdcard/Download/wifi_module.zip
echo "=== install ==="
rm -rf "$MODDIR"
mkdir -p "$MODDIR"
cd "$MODDIR" || exit 1
unzip -o "$ZIP" 2>&1 | tail -5
chmod 755 post-fs-data.sh service.sh 2>/dev/null
chmod 644 module.prop 2>/dev/null
echo "--- files ---"
ls -l
echo
echo "--- module.prop ---"
cat module.prop
