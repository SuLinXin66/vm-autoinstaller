#!/usr/bin/env bash
set -euo pipefail

# 通过 Xpra 将 VM 内的 Chrome 浏览器无缝转发到宿主机桌面
# Chrome 窗口将直接出现在宿主机桌面上，与原生应用无差别

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/sys.sh"
source "${PROJECT_ROOT}/lib/pkg.sh"
source "${PROJECT_ROOT}/lib/vm.sh"

[[ -f "${PROJECT_ROOT}/config.env" ]] || { echo "错误: config.env 不存在，请先 cp config.env.example config.env" >&2; exit 1; }
source "${PROJECT_ROOT}/config.env"

VM_NAME="${VM_NAME:-ubuntu-server}"
VM_USER="${VM_USER:-wpsweb}"
DATA_DIR="${DATA_DIR:-${HOME}/.kvm-ubuntu}"
SSH_KEY_PATH="${DATA_DIR}/id_ed25519"

# VM 端从 xpra.org 官方源安装，主版本号为 6
_XPRA_MIN_MAJOR=6

# 获取已安装 xpra 的主版本号，未安装则返回 0
_chrome::xpra_major_version() {
    local ver
    ver="$(xpra --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)" || true
    if [[ -z "$ver" ]]; then
        echo 0
        return
    fi
    echo "${ver%%.*}"
}

# 从 xpra.org 官方源安装最新版 xpra（确保与 VM 端版本兼容）
_chrome::install_xpra_from_official() {
    local family
    family="$(sys::distro_family)"

    sudo::ensure

    case "$family" in
        debian)
            log::info "添加 xpra.org 官方 APT 源..."
            sudo::exec bash -c 'curl -fsSL https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc'
            local codename
            codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
            local arch
            arch="$(dpkg --print-architecture)"
            sudo::exec bash -c "echo 'deb [arch=${arch} signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org/ ${codename} main' > /etc/apt/sources.list.d/xpra.list"
            sudo::exec apt-get update -qq
            sudo::exec apt-get install -y -qq xpra
            ;;
        redhat)
            log::info "添加 xpra.org 官方 YUM/DNF 源..."
            sudo::exec rpm --import https://xpra.org/xpra.asc 2>/dev/null || true
            local releasever
            releasever="$(. /etc/os-release && echo "$VERSION_ID")"
            sudo::exec bash -c "cat > /etc/yum.repos.d/xpra.repo <<'REPOEOF'
[xpra]
name=Xpra Official Repository
baseurl=https://xpra.org/repos/Fedora/\$releasever/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://xpra.org/xpra.asc
REPOEOF"
            sudo::exec dnf install -y xpra
            ;;
        arch)
            # Arch 官方仓库通常已是最新版，直接安装即可
            pkg::install xpra
            ;;
        suse)
            log::info "添加 xpra.org 官方 Zypper 源..."
            sudo::exec rpm --import https://xpra.org/xpra.asc 2>/dev/null || true
            sudo::exec zypper addrepo --refresh https://xpra.org/repos/openSUSE/xpra.repo 2>/dev/null || true
            sudo::exec zypper install -y xpra
            ;;
        *)
            log::die "不支持的发行版系列: ${family}，请手动安装 xpra >= ${_XPRA_MIN_MAJOR}.x"
            ;;
    esac
}

# 确保宿主机安装了与 VM 端版本兼容的 xpra
_chrome::ensure_xpra() {
    local current_major
    current_major="$(_chrome::xpra_major_version)"

    if (( current_major >= _XPRA_MIN_MAJOR )); then
        log::ok "宿主机 xpra 版本兼容 (v$(xpra --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1))"
        return 0
    fi

    if (( current_major > 0 )); then
        log::warn "宿主机 xpra 版本过低 (v$(xpra --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1))，需要 >= ${_XPRA_MIN_MAJOR}.x"
        log::info "从 xpra.org 官方源升级..."
    else
        log::info "宿主机未安装 xpra，从 xpra.org 官方源安装..."
    fi

    _chrome::install_xpra_from_official
    log::ok "xpra 安装完成 (v$(xpra --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -1))"
}

# ============================================================

# 检查 VM 是否存在且运行
if ! vm::exists "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 不存在，请先运行 ./startup.sh"
fi

if ! vm::is_running "$VM_NAME"; then
    log::die "VM [${VM_NAME}] 未运行，请先运行 ./start.sh"
fi

# 获取 VM IP
ip="$(vm::get_ip "$VM_NAME")" || log::die "无法获取 VM IP 地址"

# 检查 SSH 密钥
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log::die "SSH 密钥不存在: ${SSH_KEY_PATH}，请先运行 ./install.sh"
fi

# 确保宿主机 xpra 版本与 VM 端兼容
_chrome::ensure_xpra

# 停止可能残留的旧 xpra 会话（版本升级后旧进程仍在运行会导致协议不兼容）
_chrome::_cleanup_stale_sessions() {
    local remote_ver
    remote_ver="$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${VM_USER}@${ip}" "xpra --version 2>/dev/null" 2>/dev/null)" || true

    local sessions
    sessions="$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${VM_USER}@${ip}" "xpra list 2>/dev/null | grep -c LIVE" 2>/dev/null)" || sessions="0"

    if (( sessions > 0 )); then
        log::info "清理 VM 端残留的 xpra 会话..."
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${VM_USER}@${ip}" "xpra stop --all 2>/dev/null; pkill -u \$(whoami) -f 'xpra' 2>/dev/null || true" 2>/dev/null || true
        sleep 2
    fi
}
_chrome::_cleanup_stale_sessions

log::info "通过 Xpra 启动 Chrome (VM: ${VM_USER}@${ip})..."
log::info "Chrome 窗口将无缝出现在宿主机桌面上"

# 构建 SSH 参数（用于 Xpra 内部的 SSH 连接）
SSH_OPTS="ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Xpra seamless 模式：启动远程 Chrome 并直接转发窗口到宿主机
exec xpra start "ssh://${VM_USER}@${ip}/" \
    --ssh="$SSH_OPTS" \
    --start-child="google-chrome-stable --no-sandbox --disable-gpu" \
    --opengl=no \
    --resize-display=no \
    --exit-with-children
