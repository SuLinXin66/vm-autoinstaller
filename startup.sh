#!/usr/bin/env bash
set -euo pipefail

# 智能入口脚本：自动判断 VM 状态并执行相应操作
# - VM 不存在 → 执行 install.sh（完整安装）
# - VM 已存在 → 执行 start.sh（启动 VM）

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/vm.sh"

[[ -f "${PROJECT_ROOT}/config.env" ]] || { echo "错误: config.env 不存在，请先 cp config.env.example config.env" >&2; exit 1; }
source "${PROJECT_ROOT}/config.env"

VM_NAME="${VM_NAME:-ubuntu-server}"

sudo::ensure

if vm::exists "$VM_NAME"; then
    log::info "检测到 VM [${VM_NAME}] 已安装，直接启动..."
    exec "${PROJECT_ROOT}/start.sh" "$@"
else
    log::info "VM [${VM_NAME}] 尚未安装，开始完整安装流程..."
    exec "${PROJECT_ROOT}/install.sh" "$@"
fi
