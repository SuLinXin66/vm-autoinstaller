#!/usr/bin/env bash
set -euo pipefail

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

if ! vm::exists "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 不存在，请先运行 ${APP_NAME} setup"
fi

if ! vm::is_running "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 未运行"
fi

ip="$(vm::get_ip "$VM_NAME")" || log::die "无法获取 VM IP 地址"

ssh_args=(-A -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ -f "$SSH_KEY_PATH" ]]; then
    ssh_args+=(-i "$SSH_KEY_PATH")
fi

# Sync host terminfo to VM for modern terminals (kitty, alacritty, wezterm, ghostty, foot, etc.)
# One-time per terminal type; cached in DATA_DIR so subsequent connections are instant.
_ensure_vm_terminfo() {
    local term="${TERM:-}"
    case "$term" in
        xterm|xterm-256color|vt100|vt220|linux|dumb|screen|screen-256color|tmux|tmux-256color|"")
            return 0 ;;
    esac

    local marker_dir="${DATA_DIR}/.terminfo-synced"
    [[ -f "${marker_dir}/${term}" ]] && return 0

    command -v infocmp &>/dev/null || return 0
    infocmp "$term" &>/dev/null 2>&1 || return 0

    if infocmp -a "$term" 2>/dev/null \
        | ssh "${ssh_args[@]}" "${VM_USER}@${ip}" \
              "mkdir -p ~/.terminfo && tic -x -o ~/.terminfo /dev/stdin" 2>/dev/null; then
        mkdir -p "$marker_dir"
        touch "${marker_dir}/${term}"
    fi
}
_ensure_vm_terminfo

log::info "连接到 ${VM_USER}@${ip}..."
exec ssh "${ssh_args[@]}" "${VM_USER}@${ip}"
