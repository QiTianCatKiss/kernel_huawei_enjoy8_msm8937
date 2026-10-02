#!/system/bin/sh
for INI in /vendor/firmware/wlan/prima/WCNSS_qcom_cfg.ini /vendor/etc/wifi/WCNSS_qcom_cfg.ini; do
echo "########## $INI ##########"
echo "--- size/lines ---"
wc -c "$INI" 2>/dev/null
echo "--- non-comment lines ---"
grep -vE '^\s*#|^\s*$' "$INI" 2>/dev/null | head -60
echo
done
