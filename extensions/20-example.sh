#!/bin/bash
# Extension: example
# Description: 扩展脚本示例模板 — 复制此文件并修改来创建新扩展
#
# 使用方法：
#   1. 复制此文件：cp extensions/20-example.sh extensions/30-my-app.sh
#   2. 修改脚本内容，替换下方的安装逻辑
#   3. 运行 ./provision.sh 将自动执行新扩展
#
# 命名规范：
#   - 格式：NN-name.sh（NN 为两位数字，控制执行顺序）
#   - 建议：10-29 基础设施，30-49 开发工具，50-69 业务应用，70+ 自定义
#
# 注意事项：
#   - 脚本以 root 权限运行
#   - 必须保证幂等（多次运行结果一致，无副作用）
#   - 标记文件是幂等的基础层，也可在脚本内部做更细粒度的检查
set -euo pipefail

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MARKER_DIR="/opt/kvm-extensions"
MARKER="${MARKER_DIR}/${EXTENSION_NAME}.done"

# 幂等检查：已安装则跳过
if [[ -f "$MARKER" ]]; then
    echo "[${EXTENSION_NAME}] 已安装，跳过"
    exit 0
fi

echo "[${EXTENSION_NAME}] 开始安装..."

# ============================================================
# 在此编写安装逻辑，例如：
#
#   apt-get update -qq
#   apt-get install -y -qq your-package
#
# 或安装 .deb 包：
#
#   curl -fsSL https://example.com/app.deb -o /tmp/app.deb
#   dpkg -i /tmp/app.deb || apt-get install -f -y
#   rm -f /tmp/app.deb
#
# ============================================================

echo "[${EXTENSION_NAME}] 此为示例扩展，无实际安装操作"

# 标记完成
mkdir -p "$MARKER_DIR"
date -Iseconds > "$MARKER"
echo "[${EXTENSION_NAME}] 安装完成"
