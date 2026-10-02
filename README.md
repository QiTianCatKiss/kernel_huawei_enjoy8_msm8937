# LDN-AL20 内核（3.18.66-ByQiTianCatKiss）

华为畅享 8（LDN-AL20）的定制内核源码、构建脚本与 WiFi 启动模块。

- **设备**：Huawei Enjoy 8 / LDN-AL20（骁龙 430 MSM8937，arm64）
- **内核**：Linux 3.18.66（上游华为分支 `LA.UM.6.5.r1-03000-8x96.0`）
- **版本名**：`3.18.66-ByQiTianCatKiss`
- **状态**：WiFi 已在真机实测可用（详见下文「WiFi 修复」）

> 机型关系：LDN-AL20 是 LDN-AL00 的高配版（同为 London 代号，HL1LDNM / RHL4LDNM），
> 内核完全共用，仅设备树 ID 不同。

---

## 目录结构

```
.
├── kernel-source/          内核源码树（含本项目修复，GPL v2）
│   ├── drivers/prima/      高通 prima WiFi 驱动（built-in 编译进 Image）
│   └── fs/overlayfs/       华为私有 overlayfs 补丁
├── tools/                  构建与打包脚本
│   ├── build.sh            一键编译（WSL）
│   ├── pack_kernel.py      按原厂格式重打包 kernel.img
│   └── mkv7.sh             V7 构建脚本（自定义内核名与构建日期）
├── wifi_module/            Magisk 模块（开机自动启动 WiFi）
├── stock/                  原厂内核镜像、LDN-AL20 设备树、原厂 config
├── ramdisk/                解开的原厂 ramdisk
├── LICENSE                 MIT（本项目新增部分）
└── README.md
```

---

## 一处内核功能修复

原厂源码在 3.18 内核上无法启动 WiFi，表现为加载到 `wlan0`/`p2p0` 注册完成后
整体回滚，dmesg 报 `wlan: driver load failure`。

**根因**：`hdd_wlan_startup()` 中 `hdd_open_cesium_nl_sock()` 失败会
`goto err_ptt_sock_activate_svc` 触发全量回滚。它注册的是华为 RMC（远程管理）
私有 netlink 通道，协议号 30，而 WiFi 功能完全不依赖它。

而它**必然失败**，原因是 3.18 netlink 的自举顺序缺陷：

- `netlink_create()`（`net/netlink/af_netlink.c:559`）要求
  `nl_table[protocol].registered != 0`，否则返回 `-EPROTONOSUPPORT`；
- 但 `__netlink_kernel_create()`（同文件 `:1757`）中填 `registered = 1` 的动作
  发生在 `sock_create_lite()` **之后** —— 首次占用一个全新协议号必然被拒；
- 驱动自用的 `wlan_nlink_srv` 之所以正常，是因为它用 `NETLINK_USERSOCK`(=2)，
  该号在内核 `netlink_init()` 时已注册。

**修复**：把该致命错误降级为告警，不回滚驱动。
`drivers/prima/CORE/HDD/src/wlan_hdd_main.c`（`hdd_wlan_startup()`）：

```c
#ifdef WLAN_FEATURE_RMC
   /* cesium 是华为 RMC(远程管理)私有 netlink 通道, WiFi 功能完全不依赖它。 */
   if (hdd_open_cesium_nl_sock() < 0)
   {
      pr_err("wlan: cesium nl_sock unavailable (non-fatal), continuing\n");
   }
#endif
```

协议号 `WLAN_NLINK_CESIUM` 保持原厂值 30 不变（改号无效，已实测验证）。
`drivers/staging/prima/` 下的同名文件已同步。

### 真机验证结果

| 项目 | 结果 |
|---|---|
| `dmesg` | `wlan: driver loaded` |
| 网络接口 | `wlan0` 自动 UP |
| `wlan.driver.status` | `ok` |
| 实际连接 | `CU_8TdW` @ 72Mbps，RSSI -30，score 100 |
| 蓝牙 | running |
| overlayfs | `/prets` 挂载正常 |

---

## 编译（WSL）

**必须在 WSL 原生 ext4 下编译**（`/mnt/e` 等 NTFS 不区分大小写，
`xt_TCPMSS.c` / `xt_tcpmss.c` 等 13 处文件会冲突）：

```bash
cd /mnt/e/111/ldn-al20 && bash tools/build.sh
```

工具链必须是 **GCC 4.9**（与原厂一致）。GCC 11 编出的 Image 达 33.9MB，
解压后越过 `ramdisk_addr`(0x82000000) 导致早期启动崩溃；4.9 产物 30.9MB 安全。
`build.sh` 会自动下载 LineageOS 预置工具链。

产物：`out/Image.gz`

### 自定义内核名与构建日期

`tools/mkv7.sh` 演示了本项目的做法：

```bash
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="$(date '+%a %b %d %H:%M:%S %Z %Y')"
sed -i 's/^CONFIG_LOCALVERSION=""/CONFIG_LOCALVERSION="-ByQiTianCatKiss"/' "$OUT/.config"
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT/.config"
```

`CONFIG_LOCALVERSION` 决定 `uname -r`；关闭 `CONFIG_LOCALVERSION_AUTO` 后
`scripts/setlocalversion` 不再追加 git 描述，版本串完全可控。
`KBUILD_BUILD_TIMESTAMP` 写入 `/proc/version`。

验证结果：

```
Linux localhost 3.18.66-ByQiTianCatKiss #1 SMP PREEMPT Fri Oct 02 17:03:26 CST 2026 aarch64
```

---

## 打包与刷机

按原厂 Android boot 格式打包（复用原厂全部字段与 163 个 QCDT DTB，仅更新
`kernel_size`）：

```bash
python tools/pack_kernel.py
fastboot flash kernel out/kernel.img
```

---

## WiFi 启动模块（Magisk）

原厂通过私有节点 `/proc/wifi_built_in/wifi_start` 触发 WiFi，但该节点在
发布源码树中**完全不存在**（全树 0 个 `proc_create`）。因此改用内核已导出的
sysfs 参数触发 —— `con_mode_handler()` → `kickstart_driver()`，
与原厂是同一套逻辑（首次 init，其后走 `exit + init` 等价于 insmod/rmmod）。

`wifi_module/post-fs-data.sh` 在开机早期检查 `con_mode` 节点并写入 `3`：

```sh
[ -e "$CON_MODE" ] || exit 0          # 节点不存在则说明驱动未 built-in
CUR=$(cat "$CON_MODE" 2>/dev/null)
[ "$CUR" != "0" ] && exit 0           # 已启动
chmod 600 "$CON_MODE" 2>/dev/null     # built-in 下默认 0644，root 只读
echo 3 > "$CON_MODE" 2>/dev/null
```

> `module_param_cb` 在 built-in 场景下节点权限为 0644，必须 `chmod 600`
> 才能写入。`service.sh` 为兜底重试：等待 `wlan0` 最多 30s，未出现则重发。

---

## 已知事项

- **设备树**用从原厂包提取的 `stock/ldn-al20.dtb` 重打包。源码仓库不含 LDN 整机
  dts（华为内核开发常态），但含 London 平台公共 dtsi。原厂 DTB 163 个，
  本项目产物与之逐字节一致。
- `drivers/gpu/drm/nouveau/.../aux.{c,h}` 因 Windows 保留文件名（AUX）无法落盘，
  arm64 Android 构建不涉及 nouveau，无影响。
- 原厂 config 关键华为特性已保留：HW_SYS_SYNC、HUAWEI_KSTATE、
  HUAWEI_PMU_DSM、HUAWEI_DUBAI、dm-verity 等。
- `fs/overlayfs/super.c` 含华为私有 `/prets/` 守卫，防止 system_server 因
  `IzatProvider` NoClassDefFoundError 崩溃。**请勿移除。**

---

## 致谢与许可

- 上游内核：[Miiyo/android_kernel_huawei_msm8937](https://github.com/Miiyo/android_kernel_huawei_msm8937)（GPL v2）
- prima WiFi 驱动：Qualcomm CAF `LA.UM.6.6.c32-10800-89xx.0`
- 工具链：LineageOS `android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9`

本项目新增的脚本、Magisk 模块与文档以 MIT 协议分发；
`kernel-source/` 内的内核源码遵循其原有 GNU GPL v2（见 `kernel-source/COPYING`）。