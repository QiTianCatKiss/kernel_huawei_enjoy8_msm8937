#!/system/bin/sh
echo "=== find cfg ini ==="
find /vendor -name 'WCNSS_qcom_cfg.ini' 2>/dev/null
INI=$(find /vendor -name 'WCNSS_qcom_cfg.ini' 2>/dev/null | head -1)
echo "INI=$INI"
echo
echo "=== logging / cesium / ptt / oem related keys ==="
grep -iE 'logg|cesium|ptt|oem|debug' "$INI" 2>/dev/null | head -30
echo
echo "=== total lines ==="
wc -l "$INI" 2>/dev/null
