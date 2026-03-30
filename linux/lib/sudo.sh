#!/usr/bin/env bash
# Sudo/privilege handling: detect root, wrap commands with sudo.
# Usage: source lib/sudo.sh

[[ -n "${_LIB_SUDO_LOADED:-}" ]] && return 0
_LIB_SUDO_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

_SUDO_CMD=""

sudo::_init() {
    if [[ -n "$_SUDO_CMD" ]]; then
        return 0
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        _SUDO_CMD=""
    elif command -v sudo &>/dev/null; then
        _SUDO_CMD="sudo"
    elif command -v doas &>/dev/null; then
        _SUDO_CMD="doas"
    else
        log::die "需要 root 权限，但 sudo/doas 均不可用"
    fi
}

sudo::ensure() {
    sudo::_init

    if [[ -z "$_SUDO_CMD" ]]; then
        return 0
    fi

    log::info "验证 ${_SUDO_CMD} 权限..."

    local sudo_output
    if ! sudo_output="$($_SUDO_CMD -n true 2>&1)"; then
        if echo "$sudo_output" | grep -qi "no new privileges\|no_new_privs"; then
            log::die "当前终端设置了 no_new_privs 限制，无法使用 sudo。请在系统常规终端中运行此脚本（不要使用 IDE 内置终端）"
        fi
        # -n (non-interactive) failed, try interactive fallback
        if ! $_SUDO_CMD true; then
            log::die "${_SUDO_CMD} 认证失败"
        fi
    fi

    log::ok "${_SUDO_CMD} 权限验证通过"
}

sudo::exec() {
    sudo::_init

    if [[ -z "$_SUDO_CMD" ]]; then
        "$@"
    else
        $_SUDO_CMD "$@"
    fi
}

sudo::is_root() {
    [[ "$(id -u)" -eq 0 ]]
}
