# LDN-AL20 系统底层精简模块集（slim 系列）

五个独立、可逆、互不依赖的 KernelSU / Magisk 包，针对 LDN-AL20
（骁龙 430 / 2~3GB RAM / EMUI 8.0 / Linux 3.18.66）的系统底层做精简。

> 全部改动**不删任何系统文件**，只调整内核参数、sysprop、init 服务状态
> 与应用启用状态。每个调参模块都带 `restore.sh` 一键还原。

---

## 快速开始

**安装顺序很重要：`core` 必须第一个装**（它携带公共库）。

```bash
cd /mnt/e/111/ldn-al20 && sh tools/pack_modules.sh   # 打包
# 把 out/modules/*.zip 推上手机
for m in core mem net boot debug; do
  adb push out/modules/ldn20-slim-$m.zip /data/local/tmp/
done
# 在 Magisk / KernelSU 管理器里逐个安装，或：
for m in core mem net boot debug; do
  su -c "magisk --install-module /data/local/tmp/ldn20-slim-$m.zip"
done

adb reboot
# 开机后
su -c 'sh /data/adb/ldn20-slim/slim_status.sh'
```

> `magisk --install-module` 在 KernelSU 下同样可用；
> KernelSU 管理器里直接刷 zip 也可以。

---

## 五个包

### 0. `ldn20-slim-core` — 引导包（必装）

不调任何参数，只做两件事：
- 把 `slim_common.sh` 部署到 `/data/adb/ldn20-slim/lib/`
- 把 `slim_status.sh` 部署到 `/data/adb/ldn20-slim/`
- 建立目录骨架（`backup/` `boot/` `debug/`）

其它四个模块的 `post-fs-data.sh` 都会**先检查**公共库是否已部署，
缺失时从 `core` 或任意已安装的 `slim-*` 包里补齐，
所以即使装错顺序也能自愈（只是 `core` 的 `service.sh` 会额外输出一份
安装情况汇总到 `/data/local/tmp/slim_install_status.txt`）。

### 1. `ldn20-slim-mem` — 内存与回收

| 项 | 改动 | 依据 |
|---|---|---|
| **`vm/direct_swappiness`** | 60 → **20** | ★ 本机内核独有 |
| `vm/min_free_kbytes` | 按内存自适应 → 3072/4096/6144 | 原厂过低导致频繁回收 |
| `vm/vfs_cache_pressure` | 100 → 50 | 保住页缓存，二次启动更快 |
| `vm/swappiness` | 原厂 100 → 70 | 保留 zram 收益，降低压缩开销 |
| `vm/laptop_mode` | → 0 | 延迟写回反而拖慢频繁写库 |
| `vm/oom_kill_allocating_task` | → 1 | OOM 时杀引发者而非随机后台 |
| `vm/dirty_*` | ratio 5/15、expire 200、wb 1500 | 早期平滑回写，避免攒后刷盘卡顿 |
| `read_ahead_kb` | 原厂 128 → 256 | 闪存随机读代价高 |
| I/O 调度器 | → deadline（双保险） | V8 内核编译默认已改 |
| **LMKD `minfree`** | 1536,2048,4096,16384 → **3072,4096,8192,20480** 页 | ★ 华为定制 LMK |
| LMKD `cost` / `debug_level` | / → 10 / 0 | 减少无谓扫描与打印 |
| zram `max_comp_streams` | → 2 | 4 路并行压缩与 kswapd 抢 CPU |

**★ 关于 `direct_swappiness`**：本机内核开了 `CONFIG_HUAWEI_DIRECT_SWAPPINESS`，
效果是两件事：

1. `vm/swappiness` 取值范围从 0-100 **放宽到 0-200**；
2. **新增**独立节点 `vm/direct_swappiness`（0-200，注释建议 0-60）。

源码 `mm/vmscan.c: get_scan_count()`：

```c
if (current_is_kswapd()) {
    ...
} else {
    swappiness = direct_vm_swappiness;   /* 前台直接回收走这个 */
}
```

即 kswapd 后台回收用 `swappiness`，而**前台进程触发同步回收**用
`direct_swappiness`。后者发生在用户态已经等不及的时候，同步做回收本身
就是卡顿来源 —— 调低 = 优先换出匿名页而非同步扫描。

**★ 关于 LMKD**：本机是华为定制的 `drivers/staging/android/lowmemorykiller.c`
（`CONFIG_ANDROID_LOW_MEMORY_KILLER=y`，built-in），参数在
`/sys/module/lowmemorykiller/parameters/`。原厂 `minfree` 4 档
= 6/8/16/64 MB，前两档对 2GB 机偏激进（6MB 就开始杀进程）。
本模块**只改 minfree 数值，不改 adj 档位**（adj 是 oom_score_adj 阈值，风险高）。

已合并原 `perf_module`（v3.1）的全部内容。

### 2. `ldn20-slim-net` — 网络栈

| 项 | 改动 | 理由 |
|---|---|---|
| `tcp_tw_reuse` | → 1 | 手机短连接海量 TIME_WAIT，1s 后即可复用 |
| `tcp_tw_recycle` | → 0（显式） | NAT 网络下会导致丢包 |
| `tcp_fin_timeout` | 60 → 15 | 更快回收 FIN_WAIT2 孤儿 fd |
| `tcp_fastopen` | → 1 | 省一次 RTT（该节点无条件注册，实测可写） |
| `ip_local_port_range` | 32768-60999 → 1024-65535 | 热点 + 多应用并发时端口不够 |
| `tcp_max_syn_backlog` | 128 → 1024 | 抗突发 |
| `tcp_syn_retries` / `synack` | 6/5 → 4/3 | 127s → 31s，快速失败 |
| `tcp_rmem` / `wmem` | 加大 | 无线链路 RTT 高 |
| `tcp_moderate_rcvbuf` | → 1 | 接收缓冲自动调节 |
| **`tcp_mem`** | 按内存自适应 | ★ 默认值对 2GB 机偏低 |
| `tcp_keepalive_*` | 7200/75/9 → **120/15/4** | 运营商 NAT 超时通常 30~300s，2 小时探测无意义 |
| `tcp_max_orphans` | 16384 → 8192 | 省内存 |
| `nf_conntrack_max` | → 16384 | 热点时连接数上万，不够会丢连接 |
| `icmp_msgs_burst` | 50 → 100 | 避免连带压制必要 ICMP |
| IPv6 | **不动** | 有副作用，只在文档中说明手动方法 |

**不动的项及原因**：
- `tcp_slow_start_after_idle`：默认 1，关闭后空闲恢复跳过慢启动，
  但移动网络抖动大，保守保持原样（脚本里留了注释掉的行）。
- IPv6：国内运营商下 v6 常"半可用"会让应用浪费 3~10 秒超时，
  但直接禁用有副作用（部分 app 依赖 v6 socket 探测），
  所以只暴露节点，需要时手动 `echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6`。

### 3. `ldn20-slim-boot` — 开机与后台服务

**停用的 init 服务**（`stop`，存在才动）：

`hw_diag_server`、`oeminfo_nvm`、`cust_from_init`、`libqmi_oem_main`
—— 华为 ROM 里的出厂调试/统计服务。每个都先 `getprop init.svc.<name>`
确认存在且 running 才 stop，并有一层关键服务硬保护黑名单。

**冻结的预装应用**（`pm disable-user --user 0`，可逆）：

| 包名 | 说明 | logcat 实测出现 |
|---|---|---|
| `com.huawei.vassistant` | 华为语音助手小艺 | 48 |
| `com.huawei.intelligent` | 智慧引擎建议推送 | 39 |
| `com.huawei.android.totemweather` | 华为天气 | 24 |
| `com.huawei.recsys` | 华为推荐/内容推送 | 19 |
| `com.huawei.himovie` | 华为视频预装播放器 | 16 |
| `com.huawei.nlp` | 华为 NLP 语音服务 | 12 |
| `com.huawei.gamebox` | 华为游戏中心 | 6 |

**已刻意排除的高风险包**（冻结会连锁失败）：

- `com.huawei.hwid` / `.core` / `com.huawei.hms.account`
  —— HMS 核心 / 华为账号 / 云同步，logcat 95 次
- `com.huawei.android.hwouc` —— 与 hwid 深度耦合
- `com.huawei.systemmanager` —— 系统管家，管内存/清理
- `com.huawei.android.launcher` —— 桌面
- `com.huawei.appmarket` —— EMUI 框架依赖（HwPackageManager 校验）
- `com.huawei.android.hsf` —— HSF 混合框架，核心 IPC
- `com.huawei.systemserver` —— 华为系统服务主体

另有 `EXTRA_FROZEN` 变量供你自己追加包名。

### 4. `ldn20-slim-debug` — 日志与上报

- 20 个 logcat 高频 TAG 压到 `S`（只打 error）或 `W`，
  包括华为 ROM 特有的 `HwPackageManagerService`、`HwNetworkManagementService`、
  `VoldConnector`、以及 WiFi 驱动的 `wlan0`/`cnss`/`prima`/`ioctl`/`tsched`
- 关闭 atrace / systrace 常驻开关
- 关闭厂商 ROM 常忘关的 StrictMode
- 清理 >1 天的落盘系统日志
- `kernel/printk` → `4 4 1 7`

**不动的项**：`/proc/reboot_watchdog`。它看起来像调试节点，实际是
**重启通知机制** —— 华为在关机流程里把自身 pid 写进去，内核 reboot 时
给这些 pid 发信号让它们清理挂载点，关闭会导致关机不优雅、可能丢数据。
源码见 `drivers/staging/android/hwlogger/hw_reboot_wdt.c`。

`dmesg_restrict` 也保持 0（保持可读，便于排障）。

---

## 还原

```bash
# 单模块还原
su -c 'sh /data/adb/modules/ldn20-slim-mem/restore.sh'
su -c 'sh /data/adb/modules/ldn20-slim-net/restore.sh'
su -c 'sh /data/adb/modules/ldn20-slim-boot/restore.sh'   # 支持 list/svc/frozen 子参数
su -c 'sh /data/adb/modules/ldn20-slim-debug/restore.sh'

# 只看备份了什么
su -c 'sh /data/adb/modules/ldn20-slim-mem/restore.sh list'

# 彻底清理
su -c 'rm -rf /data/adb/ldn20-slim'
```

原理：每次改参数前先把原值存进 `/data/adb/ldn20-slim/backup/<tag>`，
`restore.sh` 按 tag 写回。**备份只存第一次**，后续运行不会覆盖原始值。

---

## 实现要点

### SELinux 处理

本机 SELinux 为 Enforcing，Magisk 上下文无法写 `/proc/sys` 与部分 `/sys`。
V8+ 内核开了 `CONFIG_SECURITY_SELINUX_DEVELOP`，因此采用：

```
setenforce 0 → 写入 → setenforce 1（带重试，确认恢复成功）
```

期间若 `setenforce 0` 失败，脚本会记录日志并继续 —— 所有写入都有失败容忍，
**任何失败都不会中断开机**。

### 对抗 init.rc 重置

华为 `/vendor/etc/init/hw/init.target.rc` 里有多处
`on boot` / `on property:sys.boot_completed=1` 会重写
`vm/swappiness=100`、`read_ahead_kb=128` 等，且触发时机**晚于**
post-fs-data。

所以实际生效点在 `service.sh`（late_start），并在 +90s / +240s 各做一次
**条件补写**（只在检测到值真的被改回时才写，避免无谓 I/O）。

### 目录布局

仓库里（唯一副本，`tools/pack_modules.sh` 负责分发）：

```
modules/
├── common/                 公共库与状态脚本的唯一源
│   ├── slim_common.sh
│   └── slim_status.sh
├── ldn20-slim-core/        引导包（携带 common/ 的两份文件）
├── ldn20-slim-mem/         调参包（不含公共库）
├── ldn20-slim-net/
├── ldn20-slim-boot/
└── ldn20-slim-debug/
```

> 公共库只存一份，避免 5 处副本各自漂移。
> 打包时 `core` 拿到两份，其余四个包不含 —— 运行时从
> `/data/adb/ldn20-slim/lib/` 读取。

手机上：

```
/data/adb/ldn20-slim/
├── lib/slim_common.sh      公共库（日志、备份、写入封装、setenforce）
├── slim_status.sh          统一状态检查
├── backup/<tag>            原厂值备份
├── slim.log                运行日志（超 16KB 自动轮转）
├── mfk_target              min_free_kbytes 目标值（跨进程传递）
├── boot/
│   ├── stopped_services    已 stop 的 init 服务
│   └── frozen_packages     已冻结的包
└── debug/props             log.tag 原值
```

### 公共库 API

`slim_log` `slim_init` `slim_se_begin` `slim_se_end` `slim_set` `slim_setnum`
`slim_get` `slim_exists` `slim_bak` `slim_restore` `slim_has_bak`
`slim_setprop` `slim_freeze` `slim_unfreeze`

`slim_setnum` 会读回校验 —— 值没真正生效时记 `WARN` 而不是假装成功。

---

## 与 perf_module 的关系

`perf_module`（v3.1）的全部内容（swappiness / 脏页 / read_ahead /
interactive 调频）已并入 `ldn20-slim-mem`。两者同时装会重复写入，
建议**卸载 perf_module**，避免值冲突。

`wifi_module` 保留 —— V10+ 内核已自带 WiFi 自动 kickstart，
`wifi_module` 只在 V9 及更早的内核上需要。

---

## 已知的本机限制

- **无任何 UART 驱动**（`.config` 只有 `CONFIG_TTY=y`、
  `CONFIG_SERIAL_CORE=y`，无具体串口驱动），因此 `printk` 降噪收益有限，
  串口控制台与崩溃持久化（PSTORE/RAMDUMP）均不可用。
- **`CONFIG_MEMCG` 关闭**：无法用 cgroup 限制单应用内存。
  应用级内存控制只能靠 LMKD 或 `pm`。
- **`CONFIG_KSM` / `CONFIG_TRANSPARENT_HUGEPAGE` 关闭**：
  无 KSM 去重、无 THP 可调。
- **华为私有 `direct_vm_swappiness` 无 `module_param` 入口**，
  只能通过 `/proc/sys/vm/direct_swappiness` 改。

---

## 免责

调整内核参数存在一定风险。本模块集的所有改动都基于**本机源码与真机
logcat 实测**，但仍建议：

1. 一次只装一个模块，观察 1~2 天再加下一个；
2. 每次改动前后跑一次 `slim_status.sh` 留档；
3. 出现异常立刻用 `restore.sh` 还原，最坏情况回退内核。
