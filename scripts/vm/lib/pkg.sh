#!/usr/bin/env bash
# VM 侧包管理辅助函数（带重试、索引新鲜度检测）
# 用法: source /opt/kvm-extensions/lib/pkg.sh

[[ -n "${_LIB_PKG_LOADED:-}" ]] && return 0
_LIB_PKG_LOADED=1

# pkg::apt_update — 带重试的 apt-get update
#   - 如果索引在 1 小时内更新过，跳过（cloud-init 刚跑完时适用）
#   - 失败时最多重试 3 次，每次间隔 5 秒
#   - 传参 --force 跳过新鲜度检测强制更新
pkg::apt_update() {
    local force=0
    [[ "${1:-}" == "--force" ]] && force=1

    if (( force == 0 )); then
        local stamp="/var/lib/apt/periodic/update-success-stamp"
        if [[ -f "$stamp" ]]; then
            local age=$(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))
            if (( age < 3600 )); then
                return 0
            fi
        fi
    fi

    local max=3
    for ((i=1; i<=max; i++)); do
        if apt-get update -q 2>&1; then
            return 0
        fi
        if ((i < max)); then
            echo "  apt-get update 失败 ($i/$max)，5 秒后重试..."
            sleep 5
        fi
    done
    echo "  错误: apt-get update 重试 ${max} 次均失败"
    return 1
}
