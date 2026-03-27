#!/usr/bin/env bash
# Cross-distro package manager abstraction.
# Supports: apt (Debian/Ubuntu), dnf (Fedora/RHEL), pacman (Arch), zypper (openSUSE)
# Usage: source lib/pkg.sh

[[ -n "${_LIB_PKG_LOADED:-}" ]] && return 0
_LIB_PKG_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/sudo.sh"
source "${SCRIPT_DIR}/sys.sh"

_PKG_MANAGER=""

# Package name mapping: generic_name -> distro-specific name
# Format: "generic:debian:redhat:arch:suse"
_PKG_MAP=(
    "qemu-kvm:qemu-kvm:qemu-kvm:qemu-full:qemu-kvm"
    "libvirt:libvirt-daemon-system:libvirt:libvirt:libvirt"
    "virt-install:virtinst:virt-install:virt-install:virt-install"
    "cloud-image-utils:cloud-image-utils:cloud-utils:cloud-image-utils:cloud-init"
    "genisoimage:genisoimage:genisoimage:cdrtools:genisoimage"
    "wget:wget:wget:wget:wget"
    "curl:curl:curl:curl:curl"
    "qemu-img:qemu-utils:qemu-img:qemu-img:qemu-tools"
    "libvirt-client:libvirt-clients:libvirt-client:libvirt:libvirt-client"
    "dnsmasq:dnsmasq:dnsmasq:dnsmasq:dnsmasq"
    "xpra:xpra:xpra:xpra:xpra"
)

pkg::_detect_manager() {
    if [[ -n "$_PKG_MANAGER" ]]; then
        return 0
    fi

    local family
    family="$(sys::distro_family)"

    case "$family" in
        debian)  _PKG_MANAGER="apt" ;;
        redhat)  _PKG_MANAGER="dnf" ;;
        arch)    _PKG_MANAGER="pacman" ;;
        suse)    _PKG_MANAGER="zypper" ;;
        *)       log::die "不支持的发行版系列：${family}" ;;
    esac
}

# Map a generic package name to the distro-specific name
pkg::_map_name() {
    local generic="$1"
    local family
    family="$(sys::distro_family)"

    local field
    case "$family" in
        debian) field=2 ;;
        redhat) field=3 ;;
        arch)   field=4 ;;
        suse)   field=5 ;;
        *)      echo "$generic"; return ;;
    esac

    for entry in "${_PKG_MAP[@]}"; do
        local key
        key="$(echo "$entry" | cut -d: -f1)"
        if [[ "$key" == "$generic" ]]; then
            local mapped
            mapped="$(echo "$entry" | cut -d: -f"$field")"
            echo "$mapped"
            return
        fi
    done

    # No mapping found, return as-is
    echo "$generic"
}

pkg::update() {
    pkg::_detect_manager
    log::info "更新包索引..."

    case "$_PKG_MANAGER" in
        apt)
            sudo::exec apt-get update -qq
            ;;
        dnf)
            sudo::exec dnf check-update -q || true
            ;;
        pacman)
            sudo::exec pacman -Sy --noconfirm
            ;;
        zypper)
            sudo::exec zypper refresh -q
            ;;
    esac
}

pkg::install() {
    pkg::_detect_manager

    local mapped_pkgs=()
    for pkg in "$@"; do
        mapped_pkgs+=("$(pkg::_map_name "$pkg")")
    done

    log::info "安装软件包: ${mapped_pkgs[*]}"

    case "$_PKG_MANAGER" in
        apt)
            sudo::exec apt-get install -y -qq "${mapped_pkgs[@]}"
            ;;
        dnf)
            sudo::exec dnf install -y -q "${mapped_pkgs[@]}"
            ;;
        pacman)
            sudo::exec pacman -S --noconfirm --needed "${mapped_pkgs[@]}"
            ;;
        zypper)
            sudo::exec zypper install -y -q "${mapped_pkgs[@]}"
            ;;
    esac
}

pkg::is_installed() {
    pkg::_detect_manager
    local pkg
    pkg="$(pkg::_map_name "$1")"

    case "$_PKG_MANAGER" in
        apt)
            dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'
            ;;
        dnf)
            rpm -q "$pkg" &>/dev/null
            ;;
        pacman)
            pacman -Qi "$pkg" &>/dev/null
            ;;
        zypper)
            rpm -q "$pkg" &>/dev/null
            ;;
    esac
}
