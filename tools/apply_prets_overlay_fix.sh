#!/bin/bash
# apply_prets_overlay_fix.sh
# Idempotently patch the Huawei overlayfs guard so /prets workdir failures
# are rescued (continue in degraded read-only mode) the same way /patch_hw is.
#
# LDN-AL20 init mounts /prets overlays with workdir=/prets/overlay/work/...
# but the semi-open-source tree only rescues /patch_hw/ paths, so the
# /prets -> /system overlay mount ABORTS, /prets/etc/permissions/*.xml never
# reach /system/etc/permissions, PackageManager can't resolve shared libraries
# (izat.xt.srv, com.android.location.provider) and system_server crashes.
#
# Usage:
#   KERNSRC=/path/to/kernel-source ./apply_prets_overlay_fix.sh
# (default: /mnt/e/111/ldn-al20/kernel-source  -- adjust to your WSL source)

KERNSRC="${KERNSRC:-/mnt/e/111/ldn-al20/kernel-source}"
F="$KERNSRC/fs/overlayfs/super.c"

if [ ! -f "$F" ]; then
    echo "[!] super.c not found at $F"
    echo "    Set KERNSRC to your actual kernel source path and re-run."
    exit 1
fi

if grep -q '"/prets/"' "$F"; then
    echo "[*] /prets guard already present in super.c -- nothing to do"
else
    python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '        if(0 == strncmp(ufs->config.workdir, PATCH_HW_PATH_NAME, strlen(PATCH_HW_PATH_NAME))){'
new = ('        if(0 == strncmp(ufs->config.workdir, PATCH_HW_PATH_NAME, strlen(PATCH_HW_PATH_NAME))\n'
       '           || 0 == strncmp(ufs->config.workdir, "/prets/", strlen("/prets/"))){')
assert old in s, "anchor not found in super.c -- source tree may differ"
s = s.replace(old, new, 1)
open(p, 'w').write(s)
print("[*] patched super.c to also rescue /prets workdir failures")
PY
fi

echo "[*] Verify in your build .config:  CONFIG_HUAWEI_PATCH_OVERLAY=y"
echo "    (stock config already sets it; it is carried into the build)"
echo "[*] Then rebuild & repack (reuse your existing V4 build flow), flash, and"
echo "    run capture_fix.bat to confirm overlay mounts now succeed."
