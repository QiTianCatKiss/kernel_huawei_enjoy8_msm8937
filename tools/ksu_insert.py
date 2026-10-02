#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 3.18 内核插入 ReSukiSU 的 Manual Hook（幂等，带锚点断言）。

构建系统 KernelSU/kernel/tools/manual_hook_check.mk 会 grep 这些字符串：
  fs/exec.c         ksu_handle_execveat
  fs/open.c         ksu_handle_faccessat
  fs/stat.c         ksu_handle_stat / ksu_handle_newfstat_ret / ksu_handle_fstat64_ret
  kernel/reboot.c   ksu_handle_sys_reboot

关键坑：fs/exec.c 自身(407 行)定义了 struct user_arg_ptr，而 KSU 的
runtime/ksud.h 也定义了同名同布局结构体 —— 所以 fs/exec.c 里绝不能 include
ksud.h，只能在函数内用 extern 声明复用本文件已有的类型，否则重复定义编译失败。
"""
import sys, os

KSRC = os.path.expanduser("~/kernsrc")
results = []

def patch(path, anchor, insert, marker):
    p = os.path.join(KSRC, path)
    s = open(p, encoding="utf-8", errors="replace").read()
    if marker in s:
        print(f"  [跳过] {path}: 已有 {marker}")
        results.append(True); return
    if anchor not in s:
        print(f"  [失败] {path}: 找不到锚点 {anchor[:60]!r}")
        results.append(False); return
    s = s.replace(anchor, anchor + insert, 1)
    open(p, "w", encoding="utf-8").write(s)
    print(f"  [已插入] {path}: {marker}")
    results.append(True)

# 1. fs/exec.c —— 必须放在 IS_ERR(filename) 检查之后，避免对错误指针解引用
patch("fs/exec.c",
      "\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n",
      "\n#ifdef CONFIG_KSU\n"
      "\textern void ksu_handle_execveat_ksud(const char *filename,\n"
      "\t\tstruct user_arg_ptr *argv, struct user_arg_ptr *envp, int *flags);\n"
      "\tksu_handle_execveat_ksud(filename->name, &argv, &envp, NULL);\n"
      "#endif\n",
      "ksu_handle_execveat_ksud")

# 2. fs/open.c —— faccessat 入口
patch("fs/open.c",
      "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n{\n",
      "#ifdef CONFIG_KSU\n"
      "\textern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
      "\t\tint *mode, int *__unused_flags);\n"
      "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
      "#endif\n",
      "ksu_handle_faccessat")

# 3. fs/stat.c —— vfs_fstatat（覆盖 stat64/lstat64/fstatat64 等所有路径）
patch("fs/stat.c",
      "int vfs_fstatat(int dfd, const char __user *filename, struct kstat *stat,\n\t\tint flag)\n{\n",
      "#ifdef CONFIG_KSU\n"
      "\textern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n"
      "\tksu_handle_stat(&dfd, &filename, &flag);\n"
      "#endif\n",
      "ksu_handle_stat")

# 4. fs/stat.c —— newfstatat 返回前
patch("fs/stat.c",
      "\terror = vfs_fstatat(dfd, filename, &stat, flag);\n\tif (error)\n\t\treturn error;\n\treturn cp_new_stat(&stat, statbuf);\n",
      "#ifdef CONFIG_KSU\n"
      "\t{\n"
      "\t\textern void ksu_handle_newfstat_ret(unsigned int *fd,\n"
      "\t\t\tstruct stat __user **statbuf_ptr);\n"
      "\t\tunsigned int __ksu_fd = (unsigned int)dfd;\n"
      "\t\tksu_handle_newfstat_ret(&__ksu_fd, &statbuf);\n"
      "\t}\n"
      "#endif\n",
      "ksu_handle_newfstat_ret")

# 5. fs/stat.c —— fstatat64 返回前
patch("fs/stat.c",
      "\terror = vfs_fstatat(dfd, filename, &stat, flag);\n\tif (error)\n\t\treturn error;\n\treturn cp_new_stat64(&stat, statbuf);\n",
      "#ifdef CONFIG_KSU\n"
      "\t{\n"
      "\t\textern void ksu_handle_fstat64_ret(unsigned long *fd,\n"
      "\t\t\tstruct stat64 __user **statbuf_ptr);\n"
      "\t\tunsigned long __ksu_fd64 = (unsigned long)dfd;\n"
      "\t\tksu_handle_fstat64_ret(&__ksu_fd64, &statbuf);\n"
      "\t}\n"
      "#endif\n",
      "ksu_handle_fstat64_ret")

# 6. kernel/reboot.c（3.12+ 在 reboot.c；若不在则回退 kernel/sys.c）
reboot_file = None
for cand in ("kernel/reboot.c", "kernel/sys.c"):
    p = os.path.join(KSRC, cand)
    if os.path.exists(p) and "SYSCALL_DEFINE4(reboot" in open(p, encoding="utf-8", errors="replace").read():
        reboot_file = cand
        break
if reboot_file:
    patch(reboot_file,
          "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n\t\tvoid __user *, arg)\n{\n",
          "#ifdef CONFIG_KSU\n"
          "\textern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n"
          "\t\tvoid __user **arg);\n"
          "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
          "#endif\n",
          "ksu_handle_sys_reboot")
else:
    print("  [失败] 找不到 reboot 系统调用定义")
    results.append(False)

print()
print(f"=== 成功 {sum(results)} / {len(results)} ===")
sys.exit(0 if all(results) else 1)
