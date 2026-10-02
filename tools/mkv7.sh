#!/bin/bash
# mkv7.sh — 构建定制内核 V7
#   内核名称 (uname -r): 3.18.66-ByQiTianCatKiss
#   构建日期: 编译时的当前时间
#   包含 cesium netlink 非致命修复（WiFi 修复）+ overlayfs /prets 守卫
#
# 相比 mkv6i.sh 的改动：
#   CONFIG_LOCALVERSION: "-g64b02e8" → "-ByQiTianCatKiss"
#   KBUILD_BUILD_TIMESTAMP: 固定值 → 编译时当前时间
set -e

KSRC=$HOME/kernsrc
OUT=$HOME/ldn-build-v7
STOCKCFG=$HOME/ldn-al20_stock_config

KVER_NAME="ByQiTianCatKiss"

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

cp "$STOCKCFG" "$OUT/.config"

# --- 内核名称 ---
sed -i "s/^CONFIG_LOCALVERSION=\"\"/CONFIG_LOCALVERSION=\"-$KVER_NAME\"/" "$OUT/.config"
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT/.config"

for k in WLAN_FEATURE_11W QCOM_VOWIFI_11R ENABLE_LINUX_REG WLAN_OFFLOAD_PACKETS \
         PRIMA_WLAN_LFR PRIMA_WLAN_OKC PRIMA_WLAN_11AC_HIGH_TP NL80211_TESTMODE; do
  sed -i "s/^# CONFIG_$k is not set/CONFIG_$k=y/" "$OUT/.config"
done
sed -i 's/^CONFIG_HUAWEI_CFI=y/# CONFIG_HUAWEI_CFI is not set/' "$OUT/.config"
sed -i 's/^# CONFIG_HUAWEI_PATCH_OVERLAY is not set/CONFIG_HUAWEI_PATCH_OVERLAY=y/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG=y/# CONFIG_MODULE_SIG is not set/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG_ALL=y/# CONFIG_MODULE_SIG_ALL is not set/' "$OUT/.config"
sed -i 's/^CONFIG_MODULE_SIG_FORCE=y/# CONFIG_MODULE_SIG_FORCE is not set/' "$OUT/.config"

export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-
export KBUILD_BUILD_USER=android
export KBUILD_BUILD_HOST=localhost
export KBUILD_BUILD_VERSION=1
# 构建日期 = 编译时的当前时间
export KBUILD_BUILD_TIMESTAMP="$(date '+%a %b %d %H:%M:%S %Z %Y')"

cd "$KSRC"
make O="$OUT" olddefconfig >/dev/null 2>&1

echo "=== 关键配置 ==="
grep -E "^CONFIG_LOCALVERSION=|^CONFIG_LOCALVERSION_AUTO|^CONFIG_HZ=|^CONFIG_HUAWEI_CFI=|^CONFIG_HUAWEI_PATCH_OVERLAY=|^CONFIG_MODULE_SIG" "$OUT/.config"
echo "KBUILD_BUILD_TIMESTAMP = $KBUILD_BUILD_TIMESTAMP"

echo "=== 编译 Image.gz ==="
make O="$OUT" -j20 CONFIG_QCOM_TDLS=y CONFIG_MDNS_OFFLOAD_SUPPORT=y \
     CONFIG_PRIMA_WLAN_LFR_MBB=y CONFIG_NO_ERROR_ON_MISMATCH=y Image.gz 2>&1 | tail -12

echo "=== 结果 ==="
ls -la "$OUT/arch/arm64/boot/Image.gz"
echo "--- utsrelease ---"
cat "$OUT/include/generated/utsrelease.h"
echo "--- Linux version 字符串 ---"
strings -n 8 "$OUT/arch/arm64/boot/Image" | grep -m1 "^Linux version"

echo "=== 导出到 Windows 侧 ==="
mkdir -p /mnt/e/111/ldn-al20/out
cp "$OUT/arch/arm64/boot/Image.gz" /mnt/e/111/ldn-al20/out/Image.gz
echo "DONE. Image.gz -> /mnt/e/111/ldn-al20/out/Image.gz"
echo "Windows 侧再运行: python3 E:/111/tools/pack_kernel.py"