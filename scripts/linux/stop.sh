#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/vm.sh"
VM_NAME="${VM_NAME:-ubuntu-server}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "用法: $0 [-h|--help]"
            echo "  停止 VM [${VM_NAME}]"
            exit 0
            ;;
        *)  log::die "未知参数: $1" ;;
    esac
done

if ! vm::exists "$VM_NAME"; then
    log::info "VM [${VM_NAME}] 不存在"
    exit 0
fi

if ! vm::is_running "$VM_NAME"; then
    log::ok "VM [${VM_NAME}] 未在运行"
    exit 0
fi

log::info "停止 VM [${VM_NAME}]..."
_vm::virsh shutdown "$VM_NAME" &>/dev/null

elapsed=0
while vm::is_running "$VM_NAME"; do
    sleep 2
    (( elapsed += 2 ))
    if (( elapsed >= 60 )); then
        log::warn "VM 未在 60s 内正常关机，强制关闭..."
        _vm::virsh destroy "$VM_NAME" &>/dev/null || true
        break
    fi
done

log::ok "VM [${VM_NAME}] 已停止"
