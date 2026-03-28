#!/usr/bin/env bash
set -euo pipefail

# 启动已存在的 VM 并显示连接信息

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/vm.sh"

[[ -f "${PROJECT_ROOT}/config.env" ]] || { echo "错误: config.env 不存在，请先 cp config.env.example config.env" >&2; exit 1; }
source "${PROJECT_ROOT}/config.env"

VM_NAME="${VM_NAME:-ubuntu-server}"
VM_USER="${VM_USER:-wpsweb}"
DATA_DIR="${DATA_DIR:-${HOME}/.kvm-ubuntu}"
SSH_KEY_PATH="${DATA_DIR}/id_ed25519"

if ! vm::exists "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 不存在，请先运行 ./install.sh 或 ./setup.sh"
fi

# 设置 SSH 密钥（用于 vm::start 中的 SSH 测试）
if [[ -f "$SSH_KEY_PATH" ]]; then
    vm::set_ssh_key "$SSH_KEY_PATH"
fi

sudo::ensure

if vm_ip="$(vm::start "$VM_NAME" "$VM_USER")"; then
    # VM 就绪后执行扩展模块增量检查（已安装的秒级跳过，新增的自动执行）
    "${PROJECT_ROOT}/provision.sh" || log::warn "部分扩展模块执行失败，可稍后运行 ./provision.sh 重试"

    log::banner "VM 已就绪"
    echo ""
    echo "  连接信息："
    echo ""
    echo "    SSH:     ssh -i ${SSH_KEY_PATH} ${VM_USER}@${vm_ip}"
    echo "    密钥:    ${SSH_KEY_PATH}"
    echo ""
    echo "  快捷命令："
    echo "    ./ssh.sh           SSH 连入 VM"
    echo "    ./chrome.sh        启动 Chrome 浏览器"
    echo "    ./status.sh        查看 VM 状态"
    echo "    ./destroy.sh       销毁 VM"
    echo ""
else
    log::warn "VM 启动过程中出现问题"
    log::info "可手动检查: ./status.sh"
fi
