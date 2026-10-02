# 内核配置快照

本目录保存各版本**实际使用过的 `.config`**，用于可复现构建。

## 为什么要存快照

内核配置有约 4800 个选项，且存在多层依赖与 Kconfig 裁决逻辑：

- 有些选项 `depends on` 别的选项，改一个会连带影响一串
- choice 类选项（如 `DEFAULT_DEADLINE` / `DEFAULT_WESTWOOD`）直接改派生值会被
  `olddefconfig` 回滚
- 华为树里还有 `AndroidKernel.mk` 的 `KERNEL_CONFIG_OVERRIDE` 强制覆盖

只靠脚本从 stock 配置推导，一旦依赖链变化就无法复现出同一个内核。
存快照可保证任何人 checkout 后能编出**逐字节一致**的配置。

## 文件

| 文件 | 对应分支 | 构建脚本 | 说明 |
|---|---|---|---|
| `v11.config` | `main` | `tools/mkv11.sh` | 普通版：性能优化，关闭全部 trace/hungtask |
| `v12dbg.config` | `debug` | `tools/mkv12dbg.sh` | 调试版：开 kprobes/ftrace/hungtask/debug-info |

## 用法

```sh
# 1. 直接用快照
cp configs/v11.config <build-dir>/.config
cd ~/kernsrc && make O=<build-dir> olddefconfig
make O=<build-dir> -j20

# 2. 或用构建脚本（它会自己写配置）
bash tools/mkv11.sh
```

> 注意：`olddefconfig` 可能调整少量选项（Kconfig 会补默认值）。
> 快照里已是裁决后的结果，所以差异应该很小，可用
> `diff configs/v11.config <build-dir>/.config` 验证。

## 关键差异（v11 → v12dbg）

| 组| v11 | v12dbg |
|---|---|---|
| 总闸门 `HUAWEI_KERNEL_DEBUG` | n | **y** |
| `KPROBES` / `KRETPROBES` / `KPROBE_EVENT` | 无 | **y** |
| `FTRACE` / `FUNCTION_TRACER` / `DYNAMIC_FTRACE` | 无 | **y** |
| `FTRACE_SYSCALLS` / `STACKTRACER` / `SCHED_TRACER` | 无 | **y** |
| `DETECT_HUNG_TASK` / `LOCKUP_DETECTOR` | n | **y** |
| `DEBUG_INFO` | n | **y** |
| `SCHEDSTATS` | n | **y** |
| `MAGIC_SYSRQ_DEFAULT_ENABLE` | `0x0` | **`0x1`** |
| `MSM_KERNEL_PROTECT` | y | **n**（`depends on !FUNCTION_TRACER`） |
| WiFi / ReSukiSU / 性能项 | 相同 | 相同 |

## 必须配合的源码补丁

`.config` 单独存在**不能**让调试能力可用，还需两个源码补丁
（`main` 与 `debug` 分支都已包含）：

1. `arch/arm64/Kconfig` 里 `select HAVE_REGS_AND_STACK_ACCESS_API`
   —— `HAVE_REGS_AND_STACK_ACCESS_API` 在 `arch/Kconfig:226` 定义但全树
   无任何架构 select 它，导致 `KPROBE_EVENT` 依赖永不满足。
   工具：`tools/v12dbg_kconfig_patch.sh`（幂等）

2. `FEATURE_WLAN_TDLS` 补定义
   —— 该宏在树中无任何 `#define`，而 prima 驱动大量代码假定它已定义，
   不补则 prima 编译失败（15 个宏未声明错误）。
   工具：`tools/prima_tdls_fix.sh`（幂等，两副本都打）
