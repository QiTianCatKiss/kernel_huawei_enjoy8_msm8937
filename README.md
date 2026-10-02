# LDN-AL20 内核（3.18.66-ByQiTianCatKiss）

华为畅享 8（LDN-AL20）的定制内核源码、构建脚本与 WiFi 启动模块。

- **设备**：Huawei Enjoy 8 / LDN-AL20（骁龙 430 MSM8937，arm64）
- **内核**：Linux 3.18.66（上游华为分支 `LA.UM.6.5.r1-03000-8x96.0`）
- **版本名**：`3.18.66-ByQiTianCatKiss`
- **状态**：WiFi 已在真机实测可用（详见「WiFi 功能修复」）；ReSukiSU root 已集成

> 机型关系：LDN-AL20 是 LDN-AL00 的高配版（同为 London 代号，HL1LDNM / RHL4LDNM），
> 内核完全共用，仅设备树 ID 不同。

---

## 目录结构

```
.
├── kernel-source/          内核源码树（含本项目修复，GPL v2）
│   ├── drivers/prima/      高通 prima WiFi 驱动（built-in 编译进 Image）
│   ├── drivers/staging/prima/  同上（prima 的 staging 副本，保持同步）
│   └── fs/overlayfs/       华为私有 overlayfs 补丁
├── tools/                  构建与打包脚本
│   ├── build.sh            一键编译（WSL）
│   ├── mkv11.sh            V11 构建脚本（当前推荐，KSU 钉版 + 全部修复）
│   ├── pack_kernel.py      按原厂格式重打包 kernel.img
│   ├── wifi_proc_patch.py  补回 /proc/wifi_built_in 私有节点
│   ├── ksu_pin.sh          把 ReSukiSU 钉到 v4.2.0-rc3
│   └── ksu_exec_hook_fix.py 修复 execve 钩子接线（su 可用的关键）
├── wifi_module/            Magisk 模块（开机自动启动 WiFi，兼容旧内核）
├── perf_module/            Magisk/KernelSU 通用性能调优模块
├── stock/                  原厂内核镜像、LDN-AL20 设备树、原厂 config
├── ramdisk/                解开的原厂 ramdisk
├── LICENSE                 MIT（本项目新增部分）
└── README.md
```

---

## WiFi 功能修复（两处）

### 修复一：cesium netlink 自举失败导致驱动回滚

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

### 修复二：补回 /proc/wifi_built_in 私有节点（V10）

上面修完后驱动能加载，但**不会自己起来**。根因是触发链路缺失：

- 内置编译时 `hdd_module_init()` 故意 `return 0`，等用户态写
  `/sys/module/wlan/parameters/fwpath` 或 `con_mode` 才调 `kickstart_driver()`；
- 原厂由 `wlan_detect` → `wifi_driver_init` →
  `write /proc/wifi_built_in/wifi_start start` 触发；
- 而 `/proc/wifi_built_in/*` 属于**华为私有内核代码**，公开源码树里全树 0 个
  `proc_create` → 整条链路静默失效，WiFi 永远起不来。

此前只能靠 Magisk 模块用 root 写 `con_mode` 兜底，root 一没了就再次失效
（ReSukiSU 未生效期间正是如此）。

**修复**（`tools/wifi_proc_patch.py`，幂等标记 `LDN-AL20-BUILTIN-WIFI-TRIGGER`）：

1. 补回三个 proc 节点，让原厂 userspace 链路照常工作：
   - `/proc/wifi_built_in/wifi_start`（0644，写 `start`/`stop`）
   - `/proc/wifi_built_in/mac_addr_hw`（0644，只读）
   - `/proc/wifi_built_in/debug_level_hw`（0644，读写）
2. 加一条兜底路径：开机 20s 后自动 kickstart（`con_mode=3`，真机验证可用），
   失败则每 10s 重试，最多 6 次。

这样 **WiFi 不再依赖 Magisk / KernelSU 模块或任何 root 脚本**。

`wifi_module/` 保留给旧内核（V9 及更早）使用。

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

## ReSukiSU（内核级 root，V9 起）

3.18 内核没有 `execveat`、没有 namespace 相关的现代钩子，**只能用手工挂钩
（`CONFIG_KSU_MANUAL_HOOK`）** 模式。以下两处是让 `su` 真正可用的关键。

### 关键一：KSU 版本号必须与官方管理器配对

KernelSU 内核侧版本号是**算出来的**（`KernelSU/kernel/Kbuild`）：

```make
KSU_LOCAL_VERSION := $(shell git rev-list --count HEAD)
KSU_VERSION       := 30000 + KSU_LOCAL_VERSION + 700
```

直接 clone `main` 分支 HEAD 是 4495 commits → **35195**，比官方已发布的管理器
（`v4.2.0-rc3` = 35171）还新。管理器发现"内核比我还新"会直接拒绝工作：
装不上 `/data/adb/ksud`、给不了任何应用授权 → `su` 完全调不出来。

`tools/ksu_pin.sh` 把 KernelSU 钉到 `v4.2.0-rc3` tag：

```
切换前  4495 commits → KSU_VERSION 35195
切换后  4471 commits → KSU_VERSION 35171   describe = v4.2.0-rc3
```

> 注意：脚本用 `git checkout -f`，会丢弃本地 `kernel/Kbuild` 改动，
> 所以脚本内部会重跑 `tools/fix_flask.py`（3.18 上 `flask.h` 只存在于
> objtree，必须给 Kbuild 补 `-I$(objtree)/security/selinux` 两条 include）。

### 关键二：execve 钩子接线错误（su 不可用的真正根因）

`fs/exec.c` 的 `do_execve_common()` 里当初只挂了：

```c
ksu_handle_execveat_ksud(filename->name, &argv, &envp, NULL);
```

而 **sucompat 的全部逻辑**（把 `/system/bin/su` 重定向到 `/data/adb/ksud`）
挂在 `ksu_handle_execve()` 内部的 `do_ksu_handle_execveat_sucompat()`，
**从来没有被调用过**。所以无论 `allow_shell` / `ksud` 是否就绪，`su` 都不会被接管。

> **为什么 build 没报错**：KernelSU 的 `tools/manual_hook_check.mk` 用
> `grep -q "ksu_handle_execveat" fs/exec.c` 做检查，而我们插入的
> `ksu_handle_execveat_ksud` 正好是它的**子串** → 误判为已挂钩。

`tools/ksu_exec_hook_fix.py`（幂等标记 `KSU_EXEC_HOOK_V2`）做了两件事：

1. 把只挂 `ksu_handle_execveat_ksud()` 的块整体替换为同时调用
   `ksu_handle_execve()`；
2. 在 `/* execve succeeded */` 之后补 `ksu_handle_post_execve()`
   （exec 成功后安装 su 会话 fd，ksud 靠它识别调用方）。

**挂载点为什么是 `do_execve_common()`**：3.18 没有 `execveat` 系统调用，
`SYSCALL_DEFINE3(execve)` 与 `COMPAT_SYSCALL_DEFINE3(execve)` 都汇聚到
`do_execve_common()`，所以只改这一处即可覆盖 64 位与 32 位 compat 路径。
位置在 `if (IS_ERR(filename)) return PTR_ERR(filename);` 之后、
`do_open_exec(filename)` 之前 —— 只有在这里改写 `filename->name` 才会生效。

**对象级验证**（`mkv11.sh` 里已内置为硬性断言）：

```bash
aarch64-linux-android-objdump -dr $OUT/fs/exec.o \
  | grep -E "R_AARCH64_CALL26\s+ksu_handle_(execve|execveat_ksud|post_execve)"
# 期望 3 条 bl 重定位
```

### 附：华为 PRETS overlay 幽灵文件（不是 KSU 的问题）

`adb shell` 下 `stat /system/bin/su` 能得到 755 / 298864 字节，但 `open`/`exec`
返回 `ENOENT`，`adb pull` 报 `remote open failed`。这是华为 PRETS overlay
（`upperdir=/prets/bin`）下的幽灵文件。**与 KSU 无关** —— KSU 命中时会先改写
`filename`，根本不会去 `open` 它。真正的根因是上面那个钩子接线错误。

### 构建

```bash
bash /mnt/e/111/tools/mkv11.sh
```

脚本会依次：钉 KSU 版本 → 打 `/prets` 守卫 → 打 WiFi 补丁 → 打 execve 钩子补丁
→ 写性能配置 → `olddefconfig` → 断言关键项 → 编译 → 对象级验证 → 导出符号表。

> **增量构建技巧**：`cp -a ~/ldn-build-v10 ~/ldn-build-v11` 后构建只需 2~3 分钟。
> 但必须手动删 `include/generated/compile.h` 和 `init/version.o`，
> 否则 `KBUILD_BUILD_TIMESTAMP` 不会更新、V9/V10/V11 的 `uname -v` 无法区分。

### 装 root 用户态

内核侧只提供钩子，`su` 的用户态还需要 `/data/adb/ksud`：

```bash
adb push ksu_assets/libksud.so /data/local/tmp/libksud.so
adb push tools/ksu_bootstrap.sh /data/local/tmp/ksu_bootstrap.sh
adb shell sh /data/local/tmp/ksu_bootstrap.sh
# 日志：/data/local/tmp/ksu_bootstrap.log
```

`ksu_bootstrap.sh` 会装 `/data/adb/ksud` 与 `/data/adb/ksu/lib/libadbroot.so`，
列出已装模块，并 dump 内核侧 KSU 版本行以便与管理器版本对照。

验证：`adb shell su -c id` 应输出 `uid=0(root)`。

---

## 性能优化配置（V8 起）

内核侧（`.config`，由 `mkv11.sh` 写入并断言）：

| 项 | 值 | 理由 |
|---|---|---|
| `DEFAULT_IOSCHED` | `deadline` | cfq 在移动端是纯开销 |
| `DEFAULT_TCP_CONG` | `westwood` | 无线链路下比 cubic 更准 |
| `CPU_FREQ_STAT` | 关 | 移除持续运行时统计开销 |
| `SCHEDSTATS` | 关 | 同上 |
| `CONTEXT_SWITCH_TRACER` | 关 | 调度热路径开销 |
| `LOCKUP_DETECTOR` / `DETECT_HUNG_TASK` | 关 | 省去 softlockup 计时器 |
| `SECURITY_SELINUX_DEVELOP` | 开 | 允许运行时 `setenforce 0`（调参前提） |

> `DEFAULT_IOSCHED` / `DEFAULT_TCP_CONG` 是 Kconfig **choice 派生值**，
> 直接改这两个符号会被 `olddefconfig` 回滚，必须改 choice 本体
> （`DEFAULT_DEADLINE` / `DEFAULT_WESTWOOD`）。

用户态（`perf_module/`，Magisk 与 KernelSU 通用）：
swappiness、脏页回写、readahead、interactive 调频。

---

## 打包与刷机

按原厂 Android boot 格式打包（复用原厂全部字段与 163 个 QCDT DTB，仅更新
`kernel_size`）：

```bash
python tools/pack_kernel.py
fastboot flash kernel out/kernel.img
```

---

## WiFi 启动模块（Magisk，仅旧内核需要）

> **V10 起不再需要**。WiFi 已改为内核侧 `/proc/wifi_built_in` + 自动 kickstart，
> 不依赖任何 root 或模块。此模块保留给 V9 及更早的内核。

原厂通过私有节点 `/proc/wifi_built_in/wifi_start` 触发 WiFi，但该节点在
发布源码树中**完全不存在**（全树 0 个 `proc_create`）。因此旧做法改用内核已导出的
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
- `ERROR: modpost: Found 10 section mismatch(es)` 是 QCOM 老驱动的已知噪音，
  不影响产物，`make` 退出码为 0。
- **本机无可用崩溃持久化通道**：无 DEVMEM / PSTORE / RAMDUMP，
  且 `.config` 里没有任何 UART 驱动（只有 `CONFIG_TTY=y`、
  `CONFIG_SERIAL_CORE=y`、`CONFIG_SERIAL_EARLYCON=y`，无具体串口驱动），
  因此串口控制台与 pstore 崩溃转储均不可用。`out/symbols/` 导出的
  `System.map` / `vmlinux` 用于离线符号化。

---

## 源码版本固定说明

`KernelSU/` 不是本仓库的一部分，构建时需单独 clone 并**钉到 tag**：

```bash
git clone https://github.com/SukiSU-Ultra/SukiSU-Ultra.git ~/kernsrc/KernelSU
bash tools/ksu_pin.sh    # -> v4.2.0-rc3，KSU_VERSION 35171
```

KSU 版本号由提交数算出（见上文「关键一」），所以**必须钉 tag**，
直接用 `main` 会得到 35195 而与管理器不匹配。
`KernelSU/kernel/Kbuild` 需由 `tools/fix_flask.py` 追加两条
`-I$(objtree)/security/selinux` include（3.18 特有）。

---

## 致谢与许可

- 上游内核：[Miiyo/android_kernel_huawei_msm8937](https://github.com/Miiyo/android_kernel_huawei_msm8937)（GPL v2）
- prima WiFi 驱动：Qualcomm CAF `LA.UM.6.6.c32-10800-89xx.0`
- 工具链：LineageOS `android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9`

本项目新增的脚本、Magisk 模块与文档以 MIT 协议分发；
`kernel-source/` 内的内核源码遵循其原有 GNU GPL v2（见 `kernel-source/COPYING`）。