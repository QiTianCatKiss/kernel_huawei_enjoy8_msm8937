#!/bin/sh
# pack_modules.sh — 把 modules/ 下各模块打成可在 Magisk/KernelSU 安装的 zip
#
# 用法：
#   cd /mnt/e/111/ldn-al20 && sh tools/pack_modules.sh
#
# 产物：out/modules/ldn20-slim-*.zip
#
# 用 Python 的 zipfile 而非 zip 命令：
#   1. Windows Git Bash 下没有 zip
#   2. 需要显式设置 Unix 权限位（0755/0644），否则 Android 上脚本不可执行
#   3. 需要排除 dotfile 与 __pycache__
#
# 注意：core 模块携带公共库 slim_common.sh / slim_status.sh，
#      其余四个模块的包里不放这两份，运行时从
#      /data/adb/ldn20-slim/lib/ 读取（见各模块 post-fs-data.sh 的引导块）。
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MODS_DIR=$ROOT/modules
OUT_DIR=$ROOT/out/modules

PY=""
for C in python3 python; do
  if command -v "$C" >/dev/null 2>&1; then PY=$C; break; fi
done
[ -z "$PY" ] && { echo "找不到 python3"; exit 1; }

mkdir -p "$OUT_DIR"

"$PY" - "$MODS_DIR" "$OUT_DIR" <<'PYEOF'
import os
import sys
import zipfile

mods_dir, out_dir = sys.argv[1], sys.argv[2]
MODS = ['ldn20-slim-core', 'ldn20-slim-mem', 'ldn20-slim-net',
        'ldn20-slim-boot', 'ldn20-slim-debug', 'ldn20-sysrq']

for m in MODS:
    src = os.path.join(mods_dir, m)
    if not os.path.isdir(src):
        print('SKIP (no dir): %s' % m)
        continue
    zp = os.path.join(out_dir, m + '.zip')
    files = []
    for root, dirs, names in os.walk(src):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d != '__pycache__']
        for f in sorted(names):
            if f.startswith('.'):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, src).replace(os.sep, '/')
            files.append((rel, p))

    with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED) as z:
        for rel, p in files:
            zi = zipfile.ZipInfo(rel)
            mode = 0o755 if rel.endswith('.sh') else 0o644
            zi.external_attr = (mode & 0xFFFF) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(p, 'rb') as fh:
                z.writestr(zi, fh.read())

    # 校验
    with zipfile.ZipFile(zp) as z:
        bad = z.testzip()
        names = z.namelist()
    print('%-18s %6d bytes  %d files  %s'
          % (m + '.zip', os.path.getsize(zp), len(names),
             'OK' if not bad else 'CORRUPT:' + str(bad)))
    for n in names:
        print('    %s' % n)
PYEOF

echo
echo "=== 安装顺序（重要）==="
echo "  1. ldn20-slim-core    （必须第一个装，携带公共库）"
echo "  2. ldn20-slim-mem     （内存与回收）"
echo "  3. ldn20-slim-net     （网络栈）"
echo "  4. ldn20-slim-boot    （开机与后台服务）"
echo "  5. ldn20-slim-debug   （日志与上报）"
echo
echo "  -- 以下独立于 slim 系列，随时可装/卸 --"
echo "  6. ldn20-sysrq        （sysrq 调试入口，V10/V11 即可用）"
echo
echo "装完重启，然后： su -c 'sh /data/adb/ldn20-slim/slim_status.sh'"
echo "sysrq 状态：      cat /data/local/tmp/sysrq_status.txt"
echo "产物目录: $OUT_DIR"
