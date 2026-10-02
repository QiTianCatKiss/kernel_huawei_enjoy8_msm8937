#!/bin/bash
# 验证：给 prima 注入 -DFEATURE_WLAN_TDLS 后完整编译是否通过
#
# 已确认的事实：
#   - 驱动编译开关是 CONFIG_PRONTO_WLAN=y（不是 CONFIG_PRIMA_WLAN）
#     drivers/Makefile:185  obj-$(CONFIG_PRONTO_WLAN) += prima/
#     但 drivers/prima/Kconfig:22 的子项在 PRIMA_WLAN 下 -> config 存在错位
#   - drivers/prima/Makefile 是 OOT 风格但被内建（wlan.o 7.2MB 链进 vmlinux）
#   - FEATURE_WLAN_TDLS 全树无 #define，而 wlan_hdd_tdls.h:37 起整份内容
#     被 #ifdef 包住 -> 树是按"TDLS 应被定义"写的，只缺定义
#
# 用法： bash tools/try_tdls_fix.sh
set -u
KSRC=${KSRC:-$HOME/kernsrc}
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=$HOME/aarch64-linux-android-4.9/bin/aarch64-linux-android-
export KBUILD_BUILD_USER=android KBUILD_BUILD_HOST=localhost

BUILD=${BUILD:-$HOME/ldn-build-tdls}
BASE=${BASE:-$HOME/ldn-build-v10/.config}

rm -rf "$BUILD"; mkdir -p "$BUILD"
cp "$BASE" "$BUILD/.config"
cd "$KSRC" || exit 1
make O="$BUILD" olddefconfig >/dev/null 2>&1

echo "开关确认:"
grep -E "^CONFIG_PRONTO_WLAN=" "$BUILD/.config" | head -1
echo

export KBUILD_CFLAGS="-DFEATURE_WLAN_TDLS"
make O="$BUILD" -j20 > "$BUILD/log.txt" 2>&1
RC=$?
unset KBUILD_CFLAGS

echo "make 退出码: $RC"
echo "error 行数: $(grep -c 'error:' "$BUILD/log.txt")"
echo
echo "=== 前 20 条错误 ==="
grep -m 20 "error:" "$BUILD/log.txt"
echo
echo "=== 最后 10 行 ==="
tail -10 "$BUILD/log.txt"
