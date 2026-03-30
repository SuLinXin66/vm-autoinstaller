#!/usr/bin/env bash
# Logging module with colored output, timestamps, and step tracking.
# Usage: source lib/log.sh

[[ -n "${_LIB_LOG_LOADED:-}" ]] && return 0
_LIB_LOG_LOADED=1

# --- Color support detection ---

_LOG_USE_COLOR=0
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    if command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
        _LOG_USE_COLOR=1
    fi
fi

_LOG_RED=""
_LOG_GREEN=""
_LOG_YELLOW=""
_LOG_BLUE=""
_LOG_CYAN=""
_LOG_BOLD=""
_LOG_RESET=""

if (( _LOG_USE_COLOR )); then
    _LOG_RED="\033[0;31m"
    _LOG_GREEN="\033[0;32m"
    _LOG_YELLOW="\033[0;33m"
    _LOG_BLUE="\033[0;34m"
    _LOG_CYAN="\033[0;36m"
    _LOG_BOLD="\033[1m"
    _LOG_RESET="\033[0m"
fi

# --- Step counter ---

_LOG_STEP_CURRENT=0
_LOG_STEP_TOTAL=0

log::set_total_steps() {
    _LOG_STEP_TOTAL="$1"
    _LOG_STEP_CURRENT=0
}

# --- Core logging functions ---

_log::_ts() {
    printf "%s" "$(date '+%H:%M:%S')"
}

_log::_print() {
    local color="$1" label="$2"
    shift 2
    local ts
    ts="$(_log::_ts)"
    printf "${color}[%-5s]${_LOG_RESET} ${_LOG_BOLD}[%s]${_LOG_RESET} %s\n" \
        "$label" "$ts" "$*" >&2
}

log::info() {
    _log::_print "$_LOG_BLUE" "INFO" "$@"
}

log::warn() {
    _log::_print "$_LOG_YELLOW" "WARN" "$@"
}

log::error() {
    _log::_print "$_LOG_RED" "ERROR" "$@"
}

log::ok() {
    _log::_print "$_LOG_GREEN" "OK" "$@"
}

log::step() {
    (( ++_LOG_STEP_CURRENT ))
    local prefix=""
    if (( _LOG_STEP_TOTAL > 0 )); then
        prefix="[${_LOG_STEP_CURRENT}/${_LOG_STEP_TOTAL}] "
    fi
    printf "${_LOG_CYAN}${_LOG_BOLD}>>> %s%s${_LOG_RESET}\n" "$prefix" "$*" >&2
}

log::die() {
    log::error "$@"
    exit 1
}

log::separator() {
    printf "${_LOG_CYAN}%s${_LOG_RESET}\n" \
        "────────────────────────────────────────────────────" >&2
}

log::banner() {
    log::separator
    printf "${_LOG_CYAN}${_LOG_BOLD}  %s${_LOG_RESET}\n" "$*" >&2
    log::separator
}
