#!/usr/bin/env bash
# System detection: distro, architecture, KVM capability, libvirt status.
# Usage: source lib/sys.sh

[[ -n "${_LIB_SYS_LOADED:-}" ]] && return 0
_LIB_SYS_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/sudo.sh"

# Cached values
_SYS_DISTRO=""
_SYS_DISTRO_FAMILY=""
_SYS_ARCH=""

sys::detect_distro() {
    if [[ -n "$_SYS_DISTRO" ]]; then
        echo "$_SYS_DISTRO"
        return 0
    fi

    if [[ ! -f /etc/os-release ]]; then
        log::die "无法检测发行版：/etc/os-release 不存在"
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    _SYS_DISTRO="${ID}"

    case "$_SYS_DISTRO" in
        ubuntu|debian|linuxmint|pop)
            _SYS_DISTRO_FAMILY="debian" ;;
        fedora|rhel|centos|rocky|alma)
            _SYS_DISTRO_FAMILY="redhat" ;;
        arch|manjaro|endeavouros)
            _SYS_DISTRO_FAMILY="arch" ;;
        opensuse*|sles)
            _SYS_DISTRO_FAMILY="suse" ;;
        *)
            _SYS_DISTRO_FAMILY="unknown" ;;
    esac

    echo "$_SYS_DISTRO"
}

sys::distro_family() {
    [[ -z "$_SYS_DISTRO_FAMILY" ]] && sys::detect_distro >/dev/null
    echo "$_SYS_DISTRO_FAMILY"
}

sys::detect_arch() {
    if [[ -n "$_SYS_ARCH" ]]; then
        echo "$_SYS_ARCH"
        return 0
    fi
    _SYS_ARCH="$(uname -m)"
    echo "$_SYS_ARCH"
}

sys::check_kvm() {
    log::info "检测 KVM 虚拟化支持..."

    if ! grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
        log::die "CPU 不支持硬件虚拟化（vmx/svm），请在 BIOS 中启用"
    fi

    if [[ ! -e /dev/kvm ]]; then
        log::warn "/dev/kvm 不存在，尝试加载 kvm 模块..."
        sudo::exec modprobe kvm
        if grep -q "Intel" /proc/cpuinfo; then
            sudo::exec modprobe kvm_intel
        else
            sudo::exec modprobe kvm_amd
        fi

        if [[ ! -e /dev/kvm ]]; then
            log::die "KVM 模块加载失败，请确认 BIOS 已启用虚拟化"
        fi
    fi

    log::ok "KVM 虚拟化支持正常"
}

sys::check_libvirt() {
    log::info "检测 libvirtd 服务状态..."

    if ! command -v virsh &>/dev/null; then
        log::die "virsh 未安装，请先运行依赖安装"
    fi

    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        log::warn "libvirtd 未运行，正在启动..."
        sudo::exec systemctl start libvirtd
        sudo::exec systemctl enable libvirtd
    fi

    log::ok "libvirtd 服务正常运行"
}

sys::ensure_user_in_libvirt() {
    local user
    user="$(whoami)"

    if [[ "$user" == "root" ]]; then
        return 0
    fi

    local need_relogin=0

    for group in libvirt kvm; do
        if getent group "$group" &>/dev/null; then
            if ! id -nG "$user" | grep -qw "$group"; then
                log::warn "将用户 ${user} 添加到 ${group} 组..."
                sudo::exec usermod -aG "$group" "$user"
                need_relogin=1
            fi
        fi
    done

    if (( need_relogin )); then
        log::warn "用户组已变更，可能需要重新登录才能生效"
        log::warn "如果后续操作遇到权限问题，请重新登录后再试"
    fi
}

sys::ensure_bridge_firewall() {
    local bridge="${1:-virbr0}"

    if ! command -v iptables &>/dev/null; then
        return 0
    fi

    # Check if iptables INPUT policy is DROP/REJECT (firewall active)
    local policy
    policy="$(sudo::exec iptables -L INPUT -n 2>/dev/null | head -1 | grep -oE 'DROP|REJECT')" || true

    if [[ -z "$policy" ]]; then
        return 0
    fi

    # Check if virbr0 traffic is already allowed
    if sudo::exec iptables -C INPUT -i "$bridge" -j ACCEPT 2>/dev/null; then
        return 0
    fi

    log::warn "检测到防火墙阻止 ${bridge} 流量，添加放行规则..."
    sudo::exec iptables -I INPUT -i "$bridge" -j ACCEPT
    sudo::exec iptables -I FORWARD -i "$bridge" -j ACCEPT
    sudo::exec iptables -I FORWARD -o "$bridge" -j ACCEPT
    log::ok "防火墙规则已添加"
}
