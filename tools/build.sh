#!/usr/bin/env bash
# LDN-AL20 (华为畅享8, MSM8937/骁龙430) 内核一键编译脚本 —— 在 WSL(Ubuntu) 中运行
# 已实测走通: Ubuntu 22.04 + aarch64-linux-gnu-gcc 11.4, 产出与原厂一致的 3.18.66 内核
#
# 重要: 必须在 WSL 原生 ext4 (家目录) 下编译!
#   /mnt/e 等 NTFS 不区分大小写, xt_TCPMSS.c / xt_tcpmss.c 等 13 处文件冲突会导致编译失败。
#
# 用法: bash build.sh
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
KSRC="$HOME/kernsrc"      # WSL 原生文件系统上的源码树
OUT="$HOME/ldn-build"     # 编译输出目录
PRIMA_TAG="LA.UM.6.6.c32-10800-89xx.0"

# ---------- 0. 工具链 ----------
# 必须用 GCC 4.9 (与原厂一致)! GCC 11 编译的 Image 达 33.9MB,
# 解压后越过 ramdisk_addr(0x82000000) 导致早期启动崩溃; 4.9 产物 30.9MB 安全。
if [ ! -x "$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-gcc" ]; then
  echo "== 下载 GCC 4.9 预置工具链 (AOSP/LineageOS 镜像) =="
  curl -sL --retry 3 -o /tmp/gcc49.tar.gz \
    https://codeload.github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/tar.gz/refs/heads/lineage-17.1
  mkdir -p "$HOME/aarch64-linux-android-4.9"
  tar -xzf /tmp/gcc49.tar.gz -C "$HOME/aarch64-linux-android-4.9" --strip-components=1
fi
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE="$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-"

# ---------- 1. 准备源码 (首次) ----------
if [ ! -d "$KSRC" ]; then
  echo "== 导出内核源码到 WSL ext4 =="
  mkdir -p "$KSRC"
  git -C "$HERE/kernel-source" -c core.protectNTFS=false archive HEAD | tar -x -C "$KSRC"

  echo "== 补齐 prima WiFi 驱动 (仓库未含, 取 CAF 标签 $PRIMA_TAG) =="
  git clone --depth 1 -b "$PRIMA_TAG" \
    https://git.codelinaro.org/clo/la/platform/vendor/qcom-opensource/wlan/prima.git \
    "$KSRC/drivers/staging/prima"
  rm -rf "$KSRC/drivers/staging/prima/.git"
  cp -r "$KSRC/drivers/staging/prima" "$KSRC/drivers/prima"   # drivers/Makefile 引用此路径

  echo "== 修复 GCC>=10 兼容 (yylloc 多重定义) =="
  sed -i '640s/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' "$KSRC/scripts/dtc/dtc-lexer.lex.c_shipped"
  sed -i '42s/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' "$KSRC/scripts/dtc/dtc-lexer.l"
fi

# ---------- 2. 配置 ----------
# 基于原厂完整配置, 做三处必要调整:
#   - 关闭 CONFIG_HUAWEI_CFI      : 依赖 AOSP 预置 gcc4.9 的 cfi.so 插件, 外部工具链没有
#   - 打开 WLAN 特性 (11W/11R/LFR/OKC/OFFLOAD/LINUX_REG/11AC_HIGH_TP):
#     prima 该版本的代码默认按 Android 构建路径开启这些特性, 否则编不过;
#     原厂其实也是用 Android 构建路径 (这些开关不进 .config), 效果一致
#   - 打开 CONFIG_NL80211_TESTMODE: prima 的 cfg80211 testmode_cmd 需要
mkdir -p "$OUT"
sed 's/^CONFIG_HUAWEI_CFI=y/# CONFIG_HUAWEI_CFI is not set/
     s/^CONFIG_HUAWEI_CFI_TAG=.*/# CONFIG_HUAWEI_CFI_TAG is not set/
     s/^# CONFIG_WLAN_FEATURE_11W is not set/CONFIG_WLAN_FEATURE_11W=y/
     s/^# CONFIG_QCOM_VOWIFI_11R is not set/CONFIG_QCOM_VOWIFI_11R=y/
     s/^# CONFIG_ENABLE_LINUX_REG is not set/CONFIG_ENABLE_LINUX_REG=y/
     s/^# CONFIG_WLAN_OFFLOAD_PACKETS is not set/CONFIG_WLAN_OFFLOAD_PACKETS=y/
     s/^# CONFIG_PRIMA_WLAN_LFR is not set/CONFIG_PRIMA_WLAN_LFR=y/
     s/^# CONFIG_PRIMA_WLAN_OKC is not set/CONFIG_PRIMA_WLAN_OKC=y/
     s/^# CONFIG_PRIMA_WLAN_11AC_HIGH_TP is not set/CONFIG_PRIMA_WLAN_11AC_HIGH_TP=y/
     s/^# CONFIG_NL80211_TESTMODE is not set/CONFIG_NL80211_TESTMODE=y/' \
     "$HERE/stock/ldn-al20_stock_config" > "$OUT/.config"
make -C "$KSRC" O="$OUT" olddefconfig

# ---------- 3. 编译 ----------
# QCOM_TDLS / MDNS / LFR_MBB 不在 Kconfig 里, 只能通过命令行传入
# CONFIG_NO_ERROR_ON_MISMATCH=y 忽略 10 处良性段不匹配 (modpost 报错)
make -C "$KSRC" O="$OUT" -j"$(nproc)" \
  CONFIG_QCOM_TDLS=y CONFIG_MDNS_OFFLOAD_SUPPORT=y CONFIG_PRIMA_WLAN_LFR_MBB=y \
  CONFIG_NO_ERROR_ON_MISMATCH=y \
  Image.gz

# ---------- 4. 导出产物 ----------
mkdir -p "$HERE/out"
cp "$OUT/arch/arm64/boot/Image.gz" "$OUT/arch/arm64/boot/Image" "$HERE/out/"
echo
echo "== 编译完成 =="
echo "产物: $HERE/out/Image.gz  (可配合 stock/ldn-al20.dtb 重打包刷入 kernel 分区)"
