#!/bin/bash
# Extension: asdf
# Description: 安装 asdf 版本管理器，用于管理 Node.js、Go 等运行时版本
set -euo pipefail

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
MARKER_DIR="/opt/kvm-extensions"
MARKER="${MARKER_DIR}/${EXTENSION_NAME}.done"

if [[ -f "$MARKER" ]]; then
    echo "[${EXTENSION_NAME}] 已安装，跳过"
    exit 0
fi

VM_USER="${VM_USER:-wpsweb}"
USER_HOME="$(eval echo "~${VM_USER}")"
ASDF_DIR="${USER_HOME}/.asdf"

echo "[${EXTENSION_NAME}] 安装 asdf..."

# asdf 依赖
apt-get install -y -q curl git

echo "[1/2] 克隆 asdf..."
if [[ ! -d "$ASDF_DIR" ]]; then
    sudo -u "$VM_USER" git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch v0.16.7
fi

echo "[2/2] 验证..."
ASDF_VER="$(sudo -u "$VM_USER" bash -c "source '$ASDF_DIR/asdf.sh' && asdf --version" 2>/dev/null || echo '未知')"
echo "  asdf: ${ASDF_VER}"

mkdir -p "$MARKER_DIR"
date -Iseconds > "$MARKER"
echo "[${EXTENSION_NAME}] 安装完成"
