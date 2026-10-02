#!/bin/bash
# V12-debug Kconfig 补丁：arch/arm64 select HAVE_REGS_AND_STACK_ACCESS_API
# 背景：华为 3.18 树中该符号在 arch/Kconfig:226 定义但无任何架构 select，
#       导致 KPROBE_EVENT（依赖它）无法 enable。arm64 实际支持这套 API。
# 幂等：靠 MARK 标记，重复执行安全。
set -eu
KSRC=${1:-${KSRC:-$HOME/kernsrc}}
F="$KSRC/arch/arm64/Kconfig"
MARK="LDN-AL20-REGS_STACK-API"

[ -f "$F" ] || { echo "!! 找不到 $F"; exit 1; }

if grep -q "$MARK" "$F"; then
    echo "已打过补丁，跳过"
    exit 0
fi

# 定位 HAVE_KPROBES 的 select 行，在其后插入
if ! grep -q "select HAVE_KPROBES" "$F"; then
    echo "!! 找不到 'select HAVE_KPROBES' 锚点，树结构可能变化，请手工检查"
    exit 1
fi

python3 - "$F" <<'PYEOF'
import sys, io
path = sys.argv[1]
MARK = "LDN-AL20-REGS_STACK-API"
NEW_SELECT = "select HAVE_REGS_AND_STACK_ACCESS_API"
with io.open(path, encoding="utf-8") as f:
    lines = f.readlines()

out = []
done = False
for ln in lines:
    out.append(ln)
    if not done and ln.strip() == "select HAVE_KPROBES":
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(indent + NEW_SELECT + "\n")
        out.append(indent + "# " + MARK + "\n")
        done = True

if not done:
    sys.exit("anchor 'select HAVE_KPROBES' not found")

with io.open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
print("patched:", path)
PYEOF

echo "--- 校验 ---"
grep -n "HAVE_REGS_AND_STACK_ACCESS_API\|$MARK" "$F" | head -5