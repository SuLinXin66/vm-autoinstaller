#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/utils.sh"
source "${PROJECT_ROOT}/lib/vm.sh"
[[ -f "${PROJECT_ROOT}/config.env" ]] || { echo "错误: config.env 不存在，请先 cp config.env.example config.env" >&2; exit 1; }
source "${PROJECT_ROOT}/config.env"

VM_NAME="${VM_NAME:-ubuntu-server}"
DATA_DIR="${DATA_DIR:-${HOME}/.kvm-ubuntu}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)   AUTO_YES=1; shift ;;
        -h|--help)
            echo "用法: $0 [-y|--yes] [-h|--help]"
            echo "  销毁 VM [${VM_NAME}] 及其磁盘文件"
            exit 0
            ;;
        *)  log::die "未知参数: $1" ;;
    esac
done

log::banner "销毁 VM: ${VM_NAME}"

if ! vm::exists "$VM_NAME"; then
    log::info "VM [${VM_NAME}] 不存在，无需操作"
    exit 0
fi

if ! utils::confirm "确认销毁 VM [${VM_NAME}] 及其所有数据?"; then
    log::info "已取消"
    exit 0
fi

sudo::ensure
vm::destroy "$VM_NAME" "$DATA_DIR"

# 清理自动生成的 SSH 密钥对
SSH_KEY_PATH="${DATA_DIR}/id_ed25519"
if [[ -f "$SSH_KEY_PATH" ]] || [[ -f "${SSH_KEY_PATH}.pub" ]]; then
    log::info "清理 SSH 密钥对..."
    rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
    log::ok "SSH 密钥对已删除"
fi

log::banner "清理完成"
