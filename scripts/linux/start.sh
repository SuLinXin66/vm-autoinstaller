#!/usr/bin/env bash
set -euo pipefail

# 启动已存在的 VM（静默快速启动，日常使用）

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/vm.sh"

VM_NAME="${VM_NAME:-ubuntu-server}"
VM_USER="${VM_USER:-wpsweb}"
DATA_DIR="${DATA_DIR:-${HOME}/.kvm-ubuntu}"
SSH_KEY_PATH="${DATA_DIR}/id_ed25519"

if ! vm::exists "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 不存在，请先运行 ${APP_NAME} setup"
fi

[[ -f "$SSH_KEY_PATH" ]] && vm::set_ssh_key "$SSH_KEY_PATH"

# Already running — just report and exit
if vm::is_running "$VM_NAME"; then
    ip="$(vm::get_ip "$VM_NAME" 2>/dev/null)" || ip=""
    if [[ -n "$ip" ]]; then
        log::ok "VM [${VM_NAME}] 已在运行 (${VM_USER}@${ip})"
    else
        log::ok "VM [${VM_NAME}] 已在运行"
    fi
    exit 0
fi

log::info "启动 VM [${VM_NAME}]..."

if ! _vm::virsh start "$VM_NAME" &>/dev/null; then
    log::error "启动 VM [${VM_NAME}] 失败"
    exit 1
fi

# Wait for IP
ip=""
for (( i=0; i<20; i++ )); do
    sleep 3
    ip="$(vm::get_ip "$VM_NAME" 2>/dev/null)" || true
    [[ -n "$ip" ]] && break
done

if [[ -z "$ip" ]]; then
    log::ok "VM [${VM_NAME}] 已启动"
    log::warn "未获取到 IP，可稍后检查: ${APP_NAME} status"
    exit 0
fi

# Wait for SSH
for (( i=0; i<20; i++ )); do
    if _vm::_ssh_test "$VM_USER" "$ip"; then
        log::ok "VM [${VM_NAME}] 已就绪 (${VM_USER}@${ip})"
        exit 0
    fi
    sleep 3
done

log::ok "VM [${VM_NAME}] 已启动 (${VM_USER}@${ip})"
log::warn "SSH 尚未就绪，可稍后重试: ${APP_NAME} ssh"
