#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复 ReSukiSU Manual Hook 的致命接线错误 —— su 永远不可用的根因。

问题：
  fs/exec.c 的 do_execve_common() 里当初只挂了
      ksu_handle_execveat_ksud(filename->name, &argv, &envp, NULL);
  而 sucompat（把 /system/bin/su 重定向到 /data/adb/ksud 的全部逻辑）
  挂在 ksu_handle_execve() -> do_ksu_handle_execveat_sucompat() 上，
  从来没有被调用过。因此无论 allow_shell / ksud 是否就绪，su 都不会被接管。

  之所以没被 build 发现：KernelSU 的 tools/manual_hook_check.mk 用
      grep -q "ksu_handle_execveat" fs/exec.c
  做检查，而 ksu_handle_execveat_ksud 正好是它的子串 → 误判为已挂钩。

补充：
  - 3.18 没有 execveat 系统调用（无 SYSCALL_DEFINE5(execveat)），
    execve / compat_execve 都汇聚到 do_execve_common()，所以只改这一处即可。
  - do_execveat_ksud 内部在 ksu_handle_execve() 里也会被调用（受 ksud_execve_key
    控制），这里保留显式调用以兼容该 static key 关闭的情况。
  - 补上 ksu_handle_post_execve()：exec 成功后安装 su 会话 fd。

幂等：靠标记 KSU_EXEC_HOOK_V2 判断。

用法：
    python3 ksu_exec_hook_fix.py [内核源码树根目录]
    # 默认 $KSRC 或 ~/kernsrc
"""
import io
import os
import re
import sys

KSRC = (sys.argv[1] if len(sys.argv) > 1
        else os.environ.get("KSRC") or os.path.expanduser("~/kernsrc"))
TARGET = os.path.join(KSRC, "fs/exec.c")
MARK = "KSU_EXEC_HOOK_V2"

HOOK_BLOCK = """#ifdef CONFIG_KSU
\t/* --- KSU_EXEC_HOOK_V2 ---
\t * 必须调用 ksu_handle_execve()：sucompat 的全部逻辑（把 /system/bin/su
\t * 重定向到 /data/adb/ksud）都挂在它内部的 do_ksu_handle_execveat_sucompat()。
\t * 只调 ksu_handle_execveat_ksud() 是不够的 —— 后者只负责探测
\t * init second_stage / zygote，不含任何 su 逻辑，那样 su 永远不会被接管。
\t *
\t * 3.18 没有 execveat 系统调用，execve 与 compat_execve 都汇聚到本函数，
\t * 因此这里就是唯一且正确的挂载点（位于 do_open_exec(filename) 之前，
\t * 改写 filename->name 才会生效）。
\t * 3.18 恒为 AT_FDCWD + flags=0，与 ksu_handle_execve() 的前提一致。
\t */
\t{
\t\textern void ksu_handle_execveat_ksud(const char *filename,
\t\t\tstruct user_arg_ptr *argv, struct user_arg_ptr *envp, int *flags);
\t\textern int ksu_handle_execve(int *fd, const char *filename,
\t\t\tvoid *argv, void *envp, int *flags);

\t\tint ksu_fd = AT_FDCWD;
\t\tint ksu_flags = 0;

\t\tksu_handle_execveat_ksud(filename->name, &argv, &envp, NULL);
\t\tksu_handle_execve(&ksu_fd, filename->name, &argv, &envp, &ksu_flags);
\t}
\t/* --- end KSU_EXEC_HOOK_V2 --- */
#endif
"""

POST_BLOCK = """\t/* execve succeeded */
#ifdef CONFIG_KSU
\t/* KSU_EXEC_HOOK_V2: exec 成功后安装 su 会话 fd（ksud 靠它识别调用方） */
\t{
\t\textern int ksu_handle_post_execve(int *fd, const char *filename,
\t\t\tvoid *argv, void *envp, int *flags, int *retval);
\t\tint ksu_fd = AT_FDCWD;
\t\tint ksu_flags = 0;
\t\tksu_handle_post_execve(&ksu_fd, filename->name, &argv, &envp,
\t\t\t\t       &ksu_flags, &retval);
\t}
#endif
"""


def fail(msg):
    sys.stderr.write("[ksu_exec_hook_fix] ERROR: %s\n" % msg)
    sys.exit(1)


def main():
    if not os.path.isfile(TARGET):
        fail("找不到 %s" % TARGET)

    with io.open(TARGET, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if MARK in src:
        print("[ksu_exec_hook_fix] 已打过补丁，跳过。")
        return

    # ---- 1) 替换掉原来只挂 ksu_handle_execveat_ksud 的块 ----
    pat = re.compile(
        r"#ifdef CONFIG_KSU\n"
        r"(?:[^\n]*\n)*?"
        r"[^\n]*ksu_handle_execveat_ksud\(filename->name[^\n]*\n"
        r"#endif\n"
    )
    m = pat.search(src)
    if not m:
        fail("找不到原 ksu_handle_execveat_ksud 钩子块")
    src = src[:m.start()] + HOOK_BLOCK + src[m.end():]
    print("[ksu_exec_hook_fix] 已替换 execve 主钩子（含 ksu_handle_execve）")

    # ---- 2) 在 execve 成功路径补 post 钩子 ----
    anchor = "\t/* execve succeeded */\n"
    n = src.count(anchor)
    if n != 1:
        fail("'/* execve succeeded */' 出现 %d 次（期望 1 次）" % n)
    src = src.replace(anchor, POST_BLOCK, 1)
    print("[ksu_exec_hook_fix] 已插入 ksu_handle_post_execve")

    with io.open(TARGET, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)

    print("[ksu_exec_hook_fix] 完成，标记数 = %d" % src.count(MARK))


if __name__ == "__main__":
    main()
