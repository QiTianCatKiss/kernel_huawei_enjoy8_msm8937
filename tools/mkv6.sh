#!/bin/bash
# mkv6.sh -- build LDN-AL20 kernel V6 (overlay /prets fix) + wlan.ko, export artifacts
# Run inside WSL:  wsl -d Ubuntu-22.04 -u qitian bash /mnt/e/111/tools/mkv6.sh
set -e
KSRC=$HOME/kernsrc
OUT=$HOME/ldn-build-v6
rm -rf "$OUT"; mkdir -p "$OUT"

# --- apply overlay /prets fix (idempotent) ---
SUPER="$KSRC/fs/overlayfs/super.c"
if ! grep -q '"/prets/"' "$SUPER"; then
  python3 - "$SUPER" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
old='        if(0 == strncmp(ufs->config.workdir, PATCH_HW_PATH_NAME, strlen(PATCH_HW_PATH_NAME))){'
new='        if(0 == strncmp(ufs->config.workdir, PATCH_HW_PATH_NAME, strlen(PATCH_HW_PATH_NAME))\n           || 0 == strncmp(ufs->config.workdir, "/prets/", strlen("/prets/"))){'
assert old in s, "ANCHOR NOT FOUND"
s=s.replace(old,new,1)
open(p,'w').write(s)
print("[*] patched super.c for /prets")
PY
else
  echo "[*] /prets guard already present"
fi

cp /mnt/e/111/ldn-al20/stock/ldn-al20_stock_config "$OUT/.config"
sed -i 's/^CONFIG_LOCALVERSION=""/CONFIG_LOCALVERSION="-g64b02e8"/' "$OUT/.config"
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT/.config"
for k in WLAN_FEATURE_11W QCOM_VOWIFI_11R ENABLE_LINUX_REG WLAN_OFFLOAD_PACKETS \
         PRIMA_WLAN_LFR PRIMA_WLAN_OKC PRIMA_WLAN_11AC_HIGH_TP NL80211_TESTMODE; do
  sed -i "s/^# CONFIG_$k is not set/CONFIG_$k=y/" "$OUT/.config"
done
sed -i 's/^CONFIG_HUAWEI_CFI=y/# CONFIG_HUAWEI_CFI is not set/' "$OUT/.config"
sed -i 's/^# CONFIG_HUAWEI_PATCH_OVERLAY is not set/CONFIG_HUAWEI_PATCH_OVERLAY=y/' "$OUT/.config"
# 关闭模块签名强制 —— V5 内核 keyring 为空且强制验签, unsigned wlan.ko 会被拒; 关掉才能 insmod
sed -i 's/^CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG_ALL=y/# CONFIG_MODULE_SIG_ALL is not set/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG_FORCE=y/# CONFIG_MODULE_SIG_FORCE is not set/' "$OUT/.config"

export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-
export KBUILD_BUILD_USER=android
export KBUILD_BUILD_HOST=localhost
export KBUILD_BUILD_TIMESTAMP="Fri Oct 16 18:10:09 CST 2020"
export KBUILD_BUILD_VERSION=1

cd "$KSRC"
make O="$OUT" olddefconfig >/dev/null 2>&1
echo "=== V6 关键项 ==="
grep -E "^CONFIG_LOCALVERSION=|^CONFIG_HZ=|^CONFIG_HUAWEI_CFI=|^CONFIG_HUAWEI_PATCH_OVERLAY=|^CONFIG_OVERLAY_FS=" "$OUT/.config"

echo "=== 编译内核 Image.gz ==="
make O="$OUT" -j20 CONFIG_QCOM_TDLS=y CONFIG_MDNS_OFFLOAD_SUPPORT=y CONFIG_PRIMA_WLAN_LFR_MBB=y CONFIG_NO_ERROR_ON_MISMATCH=y Image.gz
ls -la "$OUT/arch/arm64/boot/Image.gz"
strings -n 8 "$OUT/arch/arm64/boot/Image" | grep "^Linux version" | head -1

echo "=== 编译 wlan.ko 外部模块 ==="
make O="$OUT" -j20 CONFIG_PRONTO_WLAN=m CONFIG_QCOM_TDLS=y CONFIG_MDNS_OFFLOAD_SUPPORT=y CONFIG_PRIMA_WLAN_LFR_MBB=y CONFIG_NO_ERROR_ON_MISMATCH=y M=drivers/staging/prima modules
WLANKO="$OUT/drivers/staging/prima/wlan.ko"
echo "wlan.ko: $WLANKO"; ls -la "$WLANKO"

echo "=== 导出到 Windows 侧 ==="
cp "$OUT/arch/arm64/boot/Image.gz" /mnt/e/111/ldn-al20/out/Image.gz
mkdir -p /mnt/e/111/wifi_module
cp "$WLANKO" /mnt/e/111/wifi_module/wlan.ko
echo "DONE. 接下来在 Windows 侧运行: python3 E:/111/tools/pack_kernel.py  (生成 out/kernel.img)，再重命名为 kernel-v6.img 刷入。"
