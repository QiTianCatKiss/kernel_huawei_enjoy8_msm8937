#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复 ReSukiSU 在 3.18 上的 flask.h 找不到问题。

原因：security/selinux/include/security.h 里 #include "flask.h"，
而 flask.h 是【构建时生成到 objtree】的（security/selinux/Makefile:
"$(addprefix $(obj)/,$(selinux-y)): $(obj)/flask.h"），srctree 里没有。
KSU 的 Kbuild 原来只加了 srctree 的两个 -I，因此报
  fatal error: flask.h: No such file or directory
补上 -I$(objtree)/security/selinux 即可。
"""
import os, sys

KBUILD = os.path.expanduser("~/kernsrc/KernelSU/kernel/Kbuild")
s = open(KBUILD, encoding="utf-8", errors="replace").read()

MARKER = "-I$(objtree)/security/selinux"
if MARKER in s:
    print("[跳过] Kbuild 已包含", MARKER)
    sys.exit(0)

ANCHOR = "ccflags-y += -I$(srctree)/security/selinux -I$(srctree)/security/selinux/include\n"
if ANCHOR not in s:
    print("[失败] 找不到锚点行"); sys.exit(1)

s = s.replace(
    ANCHOR,
    ANCHOR +
    "# flask.h / av_permissions.h 是构建时生成的，只存在于 objtree，srctree 里没有\n"
    "ccflags-y += " + MARKER + " -I$(objtree)/security/selinux/include\n",
    1)
open(KBUILD, "w", encoding="utf-8").write(s)
print("[已修补] Kbuild 增加", MARKER)
