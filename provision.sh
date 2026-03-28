#!/usr/bin/env bash
set -euo pipefail

# 扩展模块执行入口：将 extensions/ 目录中的脚本推送到 VM 并按序执行
# - 首次安装后调用：执行所有扩展
# - 增量更新时调用：仅执行新增扩展（已完成的自动跳过）
# - 可独立运行，也可被 install.sh / start.sh 自动调用

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

EXTENSIONS_DIR="${PROJECT_ROOT}/extensions"
REMOTE_DIR="/opt/kvm-extensions/scripts"

# SSH 连接参数
_provision::ssh_opts() {
    echo "-i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
}

_provision::ssh_exec() {
    local ip="$1"
    shift
    ssh $(_provision::ssh_opts) "${VM_USER}@${ip}" "$@"
}

_provision::scp_to() {
    local ip="$1" src="$2" dst="$3"
    scp $(_provision::ssh_opts) -r "$src" "${VM_USER}@${ip}:${dst}"
}

# ============================================================

sudo::ensure

# 检查 VM 状态
if ! vm::exists "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 不存在，请先运行 ./install.sh"
fi

if ! vm::is_running "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 未运行，请先运行 ./start.sh"
fi

ip="$(vm::get_ip "$VM_NAME")" || log::die "无法获取 VM IP 地址"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log::die "SSH 密钥不存在: ${SSH_KEY_PATH}"
fi

# 收集扩展脚本（按文件名排序，20-example.sh 除外）
extensions=()
if [[ -d "$EXTENSIONS_DIR" ]]; then
    while IFS= read -r -d '' f; do
        local_name="$(basename "$f")"
        # 跳过示例模板
        [[ "$local_name" == "20-example.sh" ]] && continue
        extensions+=("$f")
    done < <(find "$EXTENSIONS_DIR" -maxdepth 1 -name '*.sh' -print0 | sort -z)
fi

if [[ ${#extensions[@]} -eq 0 ]]; then
    log::info "extensions/ 目录下没有扩展脚本，跳过"
    exit 0
fi

log::banner "执行 VM 扩展模块"

# 在 VM 上创建脚本目录
_provision::ssh_exec "$ip" "sudo mkdir -p ${REMOTE_DIR}"

# 批量传输扩展脚本到 VM
log::info "传输扩展脚本到 VM..."
for ext in "${extensions[@]}"; do
    _provision::scp_to "$ip" "$ext" "/tmp/"
    _provision::ssh_exec "$ip" "sudo mv /tmp/$(basename "$ext") ${REMOTE_DIR}/ && sudo chmod +x ${REMOTE_DIR}/$(basename "$ext")"
done
log::ok "传输完成 (${#extensions[@]} 个脚本)"

# 按序执行每个扩展
installed=0
skipped=0

for ext in "${extensions[@]}"; do
    name="$(basename "$ext" .sh)"
    log::info "执行扩展: ${name}..."

    # 实时流式输出扩展脚本的执行日志
    if _provision::ssh_exec "$ip" "sudo bash ${REMOTE_DIR}/$(basename "$ext")" 2>&1; then
        # 检查是否真正执行了安装（通过输出中的"跳过"关键词判断）
        # 这里用重新检查标记文件的方式更可靠
        if _provision::ssh_exec "$ip" "test -f /opt/kvm-extensions/${name}.done" 2>/dev/null; then
            # 标记文件存在，但可能是本次创建的也可能是之前的
            # 通过脚本输出已经告知用户了
            true
        fi
        (( ++installed )) || true
    else
        log::warn "扩展 [${name}] 执行失败，继续下一个..."
    fi
done

log::banner "扩展执行完成"
log::info "共处理 ${#extensions[@]} 个扩展"
