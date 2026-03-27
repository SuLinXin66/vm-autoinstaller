#!/usr/bin/env bash
# General utility functions: download, retry, command check, wait.
# Usage: source lib/utils.sh

[[ -n "${_LIB_UTILS_LOADED:-}" ]] && return 0
_LIB_UTILS_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

utils::check_command() {
    command -v "$1" &>/dev/null
}

utils::require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! utils::check_command "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log::die "缺少必要命令: ${missing[*]}"
    fi
}

utils::download() {
    local url="$1"
    local dest="$2"
    local desc="${3:-$(basename "$url")}"

    if [[ -f "$dest" ]]; then
        log::info "文件已存在，跳过下载: ${desc}"
        return 0
    fi

    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir"

    log::info "下载 ${desc}..."

    local tmp="${dest}.tmp.$$"
    local rc=0

    if utils::check_command wget; then
        wget -q --show-progress -O "$tmp" "$url" || rc=$?
    elif utils::check_command curl; then
        curl -fL --progress-bar -o "$tmp" "$url" || rc=$?
    else
        log::die "wget 和 curl 均不可用"
    fi

    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        log::die "下载失败: ${url}"
    fi

    mv "$tmp" "$dest"
    log::ok "下载完成: ${desc}"
}

utils::wait_for() {
    local description="$1"
    local timeout="$2"
    shift 2

    log::info "等待: ${description} (超时 ${timeout}s)..."

    local elapsed=0
    local interval=5

    while (( elapsed < timeout )); do
        if "$@" &>/dev/null; then
            log::ok "${description} - 就绪"
            return 0
        fi
        sleep "$interval"
        (( elapsed += interval ))
        printf "\r  ... 已等待 %ds / %ds" "$elapsed" "$timeout" >&2
    done

    printf "\n" >&2
    log::error "${description} - 超时 (${timeout}s)"
    return 1
}

utils::confirm() {
    local prompt="$1"

    if [[ "${AUTO_YES:-}" == "1" ]] || [[ "${AUTO_YES:-}" == "true" ]]; then
        return 0
    fi

    printf "%b [y/N] " "$prompt" >&2
    local reply
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

utils::cleanup_on_exit() {
    local -a _cleanup_tasks=()

    utils::_add_cleanup() {
        _cleanup_tasks+=("$1")
    }

    utils::_run_cleanup() {
        for task in "${_cleanup_tasks[@]}"; do
            eval "$task" 2>/dev/null || true
        done
    }

    trap utils::_run_cleanup EXIT
}

utils::generate_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
}

utils::get_project_root() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

    # Walk upward until we find config.env or hit /
    while [[ "$dir" != "/" ]]; do
        if [[ -f "${dir}/config.env" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done

    # Fallback: assume parent of lib/
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}
