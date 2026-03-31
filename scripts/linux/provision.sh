#!/usr/bin/env bash
set -euo pipefail

# 扩展模块执行入口：将 extensions/ 目录中的脚本推送到 VM 并按序执行
# - 首次安装后调用：执行所有扩展
# - 增量更新时调用：仅执行新增扩展（已完成的自动跳过）
# - 可独立运行，也可被 install.sh / start.sh 自动调用

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/vm.sh"

[[ -f "${REPO_ROOT}/vm/config.env" ]] || { echo "错误: config.env 不存在，请先 cp vm/config.env.example vm/config.env" >&2; exit 1; }
source "${REPO_ROOT}/vm/config.env"

VM_NAME="${VM_NAME:-ubuntu-server}"
VM_USER="${VM_USER:-wpsweb}"
DATA_DIR="${DATA_DIR:-${HOME}/.kvm-ubuntu}"
SSH_KEY_PATH="${DATA_DIR}/id_ed25519"

EXTENSIONS_DIR="${REPO_ROOT}/vm/extensions"
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
    log::die "VM [${VM_NAME}] 不存在，请先运行 ${APP_NAME} setup"
fi

if ! vm::is_running "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 未运行，请先运行 ${APP_NAME} setup"
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

# ── 同步项目内置配置到 VM ──────────────────────────────────
DOTFILES_DIR="${REPO_ROOT}/vm/config/dotfiles"

if [[ -d "$DOTFILES_DIR" ]]; then
    log::banner "同步内置配置到 VM"

    _ssh_sync_opts=(-i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

    # .zshrc
    if [[ -f "${DOTFILES_DIR}/.zshrc" ]]; then
        log::info "同步 .zshrc..."
        scp "${_ssh_sync_opts[@]}" "${DOTFILES_DIR}/.zshrc" "${VM_USER}@${ip}:~/.zshrc" 2>/dev/null \
            && log::ok ".zshrc 已同步" \
            || log::warn ".zshrc 同步失败"
    fi

    # .config/zshrc/
    if [[ -d "${DOTFILES_DIR}/.config/zshrc" ]]; then
        log::info "同步 .config/zshrc/..."
        ssh "${_ssh_sync_opts[@]}" "${VM_USER}@${ip}" "mkdir -p ~/.config/zshrc" 2>/dev/null || true
        scp "${_ssh_sync_opts[@]}" -r "${DOTFILES_DIR}/.config/zshrc"/* "${VM_USER}@${ip}:~/.config/zshrc/" 2>/dev/null \
            && log::ok ".config/zshrc/ 已同步" \
            || log::warn ".config/zshrc/ 同步失败"
    fi

    # zsh 补全片段（整目录 scp，避免 glob * 不匹配 .gitkeep 等点开头条目）
    if [[ -d "${DOTFILES_DIR}/.config/zsh/completions" ]]; then
        log::info "同步 .config/zsh/completions/..."
        ssh "${_ssh_sync_opts[@]}" "${VM_USER}@${ip}" "mkdir -p ~/.config/zsh" 2>/dev/null || true
        scp "${_ssh_sync_opts[@]}" -r "${DOTFILES_DIR}/.config/zsh/completions" "${VM_USER}@${ip}:~/.config/zsh/" 2>/dev/null \
            && log::ok ".config/zsh/completions/ 已同步" \
            || log::warn ".config/zsh/completions/ 同步失败"
    fi

    # oh-my-posh 主题
    if [[ -f "${DOTFILES_DIR}/.config/ohmyposh/ys.omp.json" ]]; then
        log::info "同步 oh-my-posh 主题..."
        ssh "${_ssh_sync_opts[@]}" "${VM_USER}@${ip}" "mkdir -p ~/.config/ohmyposh" 2>/dev/null || true
        scp "${_ssh_sync_opts[@]}" "${DOTFILES_DIR}/.config/ohmyposh/ys.omp.json" "${VM_USER}@${ip}:~/.config/ohmyposh/ys.omp.json" 2>/dev/null \
            && log::ok "oh-my-posh 主题已同步" \
            || log::warn "oh-my-posh 主题同步失败"
    fi

    # fastfetch
    if [[ -f "${DOTFILES_DIR}/.config/fastfetch/config.jsonc" ]]; then
        log::info "同步 fastfetch 配置..."
        ssh "${_ssh_sync_opts[@]}" "${VM_USER}@${ip}" "mkdir -p ~/.config/fastfetch" 2>/dev/null || true
        scp "${_ssh_sync_opts[@]}" "${DOTFILES_DIR}/.config/fastfetch/config.jsonc" "${VM_USER}@${ip}:~/.config/fastfetch/config.jsonc" 2>/dev/null \
            && log::ok "fastfetch 配置已同步" \
            || log::warn "fastfetch 配置同步失败"
    fi

    # yazi
    if [[ -d "${DOTFILES_DIR}/.config/yazi" ]] && compgen -G "${DOTFILES_DIR}/.config/yazi/*" >/dev/null; then
        log::info "同步 yazi 配置..."
        ssh "${_ssh_sync_opts[@]}" "${VM_USER}@${ip}" "mkdir -p ~/.config/yazi" 2>/dev/null || true
        scp "${_ssh_sync_opts[@]}" -r "${DOTFILES_DIR}/.config/yazi"/* "${VM_USER}@${ip}:~/.config/yazi/" 2>/dev/null \
            && log::ok "yazi 配置已同步" \
            || log::warn "yazi 配置同步失败"
    fi

    log::info "配置同步完成"
fi
