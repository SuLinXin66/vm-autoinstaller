#!/usr/bin/env bash
# VM 侧网络辅助函数（CN_MODE 加速 / 重试 / 断点续传）
# 用法: source /opt/kvm-extensions/lib/net.sh && net::init_proxy

[[ -n "${_LIB_NET_LOADED:-}" ]] && return 0
_LIB_NET_LOADED=1

_NET_GITHUB_PROXY=""

# 初始化 GitHub 代理前缀（根据 CN_MODE 自动联动）
net::init_proxy() {
    _NET_GITHUB_PROXY="${GITHUB_PROXY:-}"
    if [[ -z "$_NET_GITHUB_PROXY" && "${CN_MODE:-0}" == "1" ]]; then
        _NET_GITHUB_PROXY="https://ghfast.top/"
    fi
}

# 为 GitHub URL 添加加速前缀
net::ghurl() { echo "${_NET_GITHUB_PROXY}${1}"; }

# 通用下载：重试 3 次 + 断点续传 + 超时 30 秒
net::download() {
    local url="$1" output="$2"
    curl -fSL -C - --retry 3 --retry-delay 3 --connect-timeout 30 "$url" -o "$output"
    chmod a+r "$output" 2>/dev/null || true
}

# GitHub releases/latest 版本号解析（兼容代理可能吞掉 302）
net::ghlatest() {
    local url="$1" location
    location="$(curl -fsSI --retry 2 --connect-timeout 15 "$url" 2>/dev/null \
        | grep -i '^location:' | tail -1)"
    if [[ -n "$location" ]]; then
        echo "$location" | sed -E 's|.*/v([^[:space:]]+).*|\1|' | tr -d '\r'
        return
    fi
    curl -fsSL --retry 2 --connect-timeout 15 "$url" 2>/dev/null \
        | grep -oP '(?<=/tag/v)[^"]+' | head -1 | tr -d '\r'
}

# git clone：HTTP/1.1 + 大缓冲区 + 重试 3 次，支持指定运行用户
net::ghclone() {
    local url="$1" dest="$2" run_as="${3:-}" max=3
    for (( _r=1; _r<=max; _r++ )); do
        local git_cmd=(git -c http.version=HTTP/1.1
                           -c http.postBuffer=524288000
                           clone --depth 1 "$url" "$dest")
        if [[ -n "$run_as" ]]; then
            if sudo -u "$run_as" "${git_cmd[@]}" 2>&1; then return 0; fi
        else
            if "${git_cmd[@]}" 2>&1; then return 0; fi
        fi
        rm -rf "$dest"
        (( _r < max )) && { echo "    clone 失败，5 秒后重试 (${_r}/${max})..."; sleep 5; }
    done
    echo "    警告: git clone 最终失败: $url"
    return 1
}
