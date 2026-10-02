# tools/ 工具清单

## 两版共用（`main` 与 `debug` 分支都有）

### 构建
| 脚本 | 用途 |
|---|---|
| `mkv11.sh` | **V11 普通版构建**（性能优化，关闭全部 trace）。`main` 分支用这个 |
| `wifi_proc_patch.py` | 补回 `/proc/wifi_built_in/{wifi_start,mac_addr_hw,debug_level_hw}` 私有节点 + 开机 20s 自动 kickstart。幂等（MARK `LDN-AL20-BUILTIN-WIFI-TRIGGER`） |
| `ksu_pin.sh` | 把 ReSukiSU 钉到 `v4.2.0-rc3`（版本号必须 ≤ 管理器，否则被拒） |
| `ksu_exec_hook_fix.py` | 修复 execve 钩子接线。3.18 无 `execveat`，su 能否调用全靠这个。幂等（MARK `KSU_EXEC_HOOK_V2`） |
| `prima_tdls_fix.sh` | **两版构建都必需**。补 `FEATURE_WLAN_TDLS` 定义，否则 prima 编译报 15 个宏未声明。幂等（MARK `LDN-AL20-ENABLE-TDLS`），对 `drivers/prima` 与 `drivers/staging/prima` 两副本都打 |

> `prima_tdls_fix.sh` 与版本无关 —— 只要重新完整编译内核就需要它。
> `mkv11.sh` 与 `mkv12dbg.sh` 都会调用它。

### 打包
| 脚本 | 用途 |
|---|---|
| `pack_modules.sh` | 把 `modules/` 各模块打成可安装 zip（用 Python zipfile，因 Git Bash 无 `zip` 且需设Unix 权限位） |
| `pack_kernel.py` | 按原厂格式重打包 `kernel.img` |
| `export-source.sh` | 导出源码包 |

### 诊断
| 脚本 | 用途 |
|---|---|
| `sysrq_on.sh` | sysrq 调试入口（开/关/状态/触发）。**不需重编译**，V10/V11 直接可用 |
| `wdiag.sh` | WiFi 状态诊断 |
| `vcheck_wifi.sh` | WiFi 修复点校验 |

---

## 仅 debug 分支

### 构建
| 脚本 | 用途 |
|---|---|
| `mkv12dbg.sh` | **V12-debug 构建**。在 V11 基础上重开 kprobes / ftrace / hung-task / debug-info / sysrq，含 26 项 config 断言 + objdump 断言 |
| `v12dbg_kconfig_patch.sh` | 在 `arch/arm64/Kconfig` 补 `select HAVE_REGS_AND_STACK_ACCESS_API`。该符号在 `arch/Kconfig:226` 定义但全树无架构 select，导致 `KPROBE_EVENT` 依赖永不满足。幂等（MARK `LDN-AL20-REGS_STACK-API`） |

> `v12dbg_kconfig_patch.sh` 其实两版都能跑（改的是通用基础设施），
> 但 `main` 分支不开 kprobes，跑它没有意义，故只留在 debug 分支。

### 排障辅助
| 脚本 | 用途 |
|---|---|
| `try_tdls_fix.sh` | 用完整编译验证 `FEATURE_WLAN_TDLS` 是否修复 prima（单文件目标会报 `No rule to make target`，必须走完整编译） |
| `find_tdls_hook.py` | 定位宏注入点：按 `FEATURE_*` 定义数排序头文件 + 统计 include 引用数 |

---

## 历史遗留（早期版本，已被上面取代）

`mkv5.sh` ~ `mkv10.sh`、`build.sh`、`fix_flask.py`、`ksu_insert.py`、
`analyze_reloc.py`、`apply_prets_overlay_fix.sh`、`extract_*.py`、
`chk_ini*.sh`、`dump_dm.sh`、`nl_dump.sh`、`kick*.sh`、`install_mod.sh`、
`push_retry.sh`

保留仅为追溯改动历史，日常构建用 `mkv11.sh`（普通）或 `mkv12dbg.sh`（调试）。

---

## 搜索陷阱备忘

给以后省时间：

| 现象 | 原因 | 对策 |
|---|---|---|
| `grep -rl xxx drivers/prima/` 卡十几分钟 | 该目录有符号链接环 | 指定精确文件路径，别递归 |
| bash 里 `awk -F: "{ if (\$1+0 >= N ...) }"` 报语法错 | `$1` 被 shell 吃掉 | 复杂文本处理写 Python 脚本 |
| `export KBUILD_CFLAGS=...` 无效 | 3.18 `Makefile:421` 用 `KBUILD_CFLAGS :=` 赋值，覆盖环境变量 | 改源码，或用 `EXTRA_CFLAGS` |
| `make drivers/prima/xxx.o` 报 `No rule to make target` | prima 不是标准 kbuild 子目录 | 走完整编译验证 |
| Kconfig `select` 行加 `/* */` 注释报 `syntax error` | Kconfig 不支持行内注释 | MARK 独占一行，以 `#` 开头 |
