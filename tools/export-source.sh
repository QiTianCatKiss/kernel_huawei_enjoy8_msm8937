#!/usr/bin/env bash
# 在 WSL 中运行: 把 kernel-source/.git 里的源码树完整导出到工作目录
# 用法: cd /mnt/e/111/ldn-al20 && bash export-source.sh
set -e
cd "$(dirname "$0")/kernel-source"
git -c core.protectNTFS=false archive HEAD | tar -x \
  --exclude='drivers/gpu/drm/nouveau/core/subdev/i2c/aux.c' \
  --exclude='drivers/gpu/drm/nouveau/nvkm/subdev/i2c/aux.c' \
  --exclude='drivers/gpu/drm/nouveau/nvkm/subdev/i2c/aux.h'
echo "导出完成 (3 个 nouveau/aux.* 被排除, Windows 保留文件名, arm64 编译用不到)"
