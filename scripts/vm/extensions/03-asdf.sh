#!/bin/bash
# Extension: asdf
# Description: 安装 asdf 版本管理器 + Node.js + Go + Rust 开发工具链，
#              配置 CN 镜像（npm/go/crates），安装 nvim conform/mason 依赖
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

source /opt/kvm-extensions/lib/net.sh
source /opt/kvm-extensions/lib/pkg.sh
net::init_proxy

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
CN_MODE="${CN_MODE:-0}"

VM_USER="${VM_USER:-$(getent passwd 1000 | cut -d: -f1)}"
USER_HOME="$(eval echo "~${VM_USER}")"
ASDF_DATA="${USER_HOME}/.asdf"
LOCAL_BIN="${USER_HOME}/.local/bin"
ARCH="$(dpkg --print-architecture)"

echo "[${EXTENSION_NAME}] 安装开发工具链..."

_as_user() {
    local _proxy_args=()
    if [[ -n "${http_proxy:-}" ]]; then
        _proxy_args=(
            http_proxy="$http_proxy" https_proxy="${https_proxy:-}"
            HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" no_proxy="${no_proxy:-}"
        )
    fi
    sudo -u "$VM_USER" env \
        HOME="$USER_HOME" \
        PATH="${LOCAL_BIN}:${ASDF_DATA}/shims:${USER_HOME}/.cargo/bin:${USER_HOME}/go/bin:/usr/local/bin:/usr/bin:/bin" \
        ASDF_DATA_DIR="$ASDF_DATA" \
        ${_proxy_args[@]+"${_proxy_args[@]}"} \
        "$@"
}

apt-get install -y -q curl ca-certificates git
sudo -u "$VM_USER" mkdir -p "$LOCAL_BIN"

# ── 1. asdf 二进制 ──────────────────────────────────────────
echo "[1/8] 安装 asdf..."
if ! _as_user bash -c 'command -v asdf &>/dev/null && asdf --version' &>/dev/null; then
    ASDF_VER="$(net::ghlatest "$(net::ghurl "https://github.com/asdf-vm/asdf/releases/latest")")"
    [[ -z "$ASDF_VER" ]] && ASDF_VER="0.18.1"

    case "$ARCH" in
        amd64) ASDF_ARCH="amd64" ;;
        arm64) ASDF_ARCH="arm64" ;;
        i386)  ASDF_ARCH="386" ;;
        *) echo "  错误: 不支持的架构: $ARCH"; exit 1 ;;
    esac

    ASDF_URL="$(net::ghurl "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VER}/asdf-v${ASDF_VER}-linux-${ASDF_ARCH}.tar.gz")"
    _tmp="$(mktemp -d)"
    if net::download "$ASDF_URL" "${_tmp}/asdf.tgz"; then
        tar xzf "${_tmp}/asdf.tgz" -C "$_tmp"
        install -m 755 "${_tmp}/asdf" "${LOCAL_BIN}/asdf"
        chown "$VM_USER:$VM_USER" "${LOCAL_BIN}/asdf"
        echo "  asdf v${ASDF_VER} 已安装"
    else
        echo "  错误: asdf 下载失败"; exit 1
    fi
    rm -rf "$_tmp"
else
    echo "  asdf 已安装: $(_as_user bash -c 'asdf --version' 2>/dev/null)"
fi

# 清理旧 bash 版仓库文件
if [[ -f "${ASDF_DATA}/asdf.sh" ]]; then
    rm -rf "${ASDF_DATA}/.git" "${ASDF_DATA}/bin" "${ASDF_DATA}/lib" "${ASDF_DATA}/test" "${ASDF_DATA}/docs" 2>/dev/null || true
    rm -f "${ASDF_DATA}/asdf.sh" "${ASDF_DATA}/Makefile" 2>/dev/null || true
fi

# zsh 补全
_as_user mkdir -p "${ASDF_DATA}/completions"
_as_user bash -c 'asdf completion zsh > "${ASDF_DATA_DIR}/completions/_asdf"' 2>/dev/null || true

# ── 2. Node.js (via asdf) ──────────────────────────────────
echo "[2/8] 安装 Node.js (via asdf)..."
if ! _as_user bash -c 'node --version' &>/dev/null; then
    _node_install='asdf plugin add nodejs 2>/dev/null || true && asdf install nodejs latest && asdf set --home nodejs latest'
    if [[ "$CN_MODE" == "1" ]]; then
        _as_user env NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node bash -c "$_node_install" \
            && echo "  Node.js: $(_as_user bash -c 'node --version' 2>/dev/null)" \
            || echo "  警告: Node.js 安装失败"
    else
        _as_user bash -c "$_node_install" \
            && echo "  Node.js: $(_as_user bash -c 'node --version' 2>/dev/null)" \
            || echo "  警告: Node.js 安装失败"
    fi
else
    echo "  已安装: $(_as_user bash -c 'node --version' 2>/dev/null)"
fi

# ── 3. Go (via asdf) ───────────────────────────────────────
echo "[3/8] 安装 Go (via asdf)..."
if ! _as_user bash -c 'go version' &>/dev/null; then
    _as_user bash -c 'asdf plugin add golang 2>/dev/null || true'
    _go_ok=false

    if [[ "$CN_MODE" == "1" ]]; then
        # asdf-golang 插件从 go.dev 下载，国内不稳定；改用 golang.google.cn 官方中国镜像
        echo "  CN_MODE: 从 golang.google.cn 下载..."
        _go_ver="$(curl -sL --max-time 15 'https://golang.google.cn/VERSION?m=text' 2>/dev/null | head -1 | sed 's/^go//')"
        if [[ -n "$_go_ver" ]]; then
            _go_arch="amd64"
            [[ "$ARCH" == "arm64" ]] && _go_arch="arm64"
            _go_tgz="$(mktemp)"
            if net::download "https://golang.google.cn/dl/go${_go_ver}.linux-${_go_arch}.tar.gz" "$_go_tgz"; then
                _go_dir="${ASDF_DATA}/installs/golang/${_go_ver}"
                sudo -u "$VM_USER" mkdir -p "$_go_dir"
                tar xzf "$_go_tgz" -C "$_go_dir"
                chown -R "$VM_USER:$VM_USER" "$_go_dir"
                _as_user bash -c "asdf set --home golang ${_go_ver}"
                _as_user bash -c 'asdf reshim golang' 2>/dev/null || true
                _go_ok=true
                echo "  Go ${_go_ver} 已安装"
            fi
            rm -f "$_go_tgz"
        fi
    fi

    if [[ "$_go_ok" != "true" ]]; then
        _as_user bash -c 'asdf install golang latest && asdf set --home golang latest' \
            && _go_ok=true \
            || echo "  警告: Go 安装失败"
    fi

    [[ "$_go_ok" == "true" ]] && echo "  Go: $(_as_user bash -c 'go version' 2>/dev/null)"
else
    echo "  已安装: $(_as_user bash -c 'go version' 2>/dev/null)"
fi

# ── 4. Rust (via rustup) ───────────────────────────────────
echo "[4/8] 安装 Rust (via rustup)..."
if ! _as_user bash -c 'rustc --version' &>/dev/null; then
    _tmp_rustup="$(mktemp)"
    if net::download "https://sh.rustup.rs" "$_tmp_rustup"; then
        if [[ "$CN_MODE" == "1" ]]; then
            _as_user env \
                RUSTUP_DIST_SERVER=https://rsproxy.cn \
                RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup \
                bash "$_tmp_rustup" -y --no-modify-path 2>&1 | tail -3
        else
            _as_user bash "$_tmp_rustup" -y --no-modify-path 2>&1 | tail -3
        fi
        _as_user bash -c 'rustup component add rust-analyzer' 2>/dev/null || true
        echo "  Rust: $(_as_user bash -c 'rustc --version' 2>/dev/null || echo '安装失败')"
    else
        echo "  警告: rustup 下载失败"
    fi
    rm -f "$_tmp_rustup"
else
    echo "  已安装: $(_as_user bash -c 'rustc --version' 2>/dev/null)"
    _as_user bash -c 'rustup component add rust-analyzer' 2>/dev/null || true
fi

# ── 5. CN 镜像配置 ─────────────────────────────────────────
if [[ "$CN_MODE" == "1" ]]; then
    echo "[5/8] 配置 CN 开发镜像..."
    # npm → npmmirror
    _as_user bash -c 'npm config set registry https://registry.npmmirror.com' 2>/dev/null || true
    # go → goproxy.cn
    _as_user bash -c 'go env -w GOPROXY=https://goproxy.cn,direct' 2>/dev/null || true
    # crates.io → rsproxy
    _as_user bash -c 'mkdir -p ~/.cargo && cat > ~/.cargo/config.toml <<EOF
[source.crates-io]
replace-with = "rsproxy-sparse"

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
EOF' 2>/dev/null || true
    echo "  npm/go/cargo 镜像已配置"
else
    echo "[5/8] 非 CN 模式，跳过镜像配置"
fi

# ── 6. nvim conform/LSP 工具 ───────────────────────────────
echo "[6/8] 安装 nvim 开发工具..."
# Go formatters
if _as_user bash -c 'command -v go' &>/dev/null; then
    echo "  安装 gofumpt, goimports..."
    _as_user bash -c 'go install mvdan.cc/gofumpt@latest' 2>/dev/null || true
    _as_user bash -c 'go install golang.org/x/tools/cmd/goimports@latest' 2>/dev/null || true
    _as_user bash -c 'asdf reshim golang' 2>/dev/null || true
fi
# npm globals (conform formatters)
if _as_user bash -c 'command -v npm' &>/dev/null; then
    echo "  安装 prettier, markdownlint-cli2..."
    _as_user bash -c 'npm install -g prettier markdownlint-cli2' 2>/dev/null || true
    _as_user bash -c 'asdf reshim nodejs' 2>/dev/null || true
fi

# ── 7. nvim Mason 同步 ─────────────────────────────────────
echo "[7/8] 同步 nvim Mason 工具..."
NVIM_CONFIG="${USER_HOME}/.config/nvim"
if [[ -d "$NVIM_CONFIG" ]] && command -v nvim &>/dev/null; then
    _nvim_preserve_env="http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,no_proxy"
    _nvim_path="${LOCAL_BIN}:${ASDF_DATA}/shims:${USER_HOME}/.cargo/bin:${USER_HOME}/go/bin:/usr/local/bin:/usr/bin:/bin"
    _nvim_env="export HOME='${USER_HOME}' PATH='${_nvim_path}' ASDF_DATA_DIR='${ASDF_DATA}'"

    sudo --preserve-env="${_nvim_preserve_env}" \
        -u "$VM_USER" bash -c "${_nvim_env}; nvim --headless '+lua require(\"mason-registry\").refresh()' '+MasonInstallAll' '+sleep 30' '+qa' 2>&1" 2>&1 | sed 's/^/    /' || true
    echo "  Mason 同步完成"
else
    echo "  跳过: nvim 或配置目录不存在"
fi

# ── 8. 验证 ────────────────────────────────────────────────
echo "[8/8] 验证工具链..."
echo "  asdf:           $(_as_user bash -c 'asdf --version' 2>/dev/null || echo '未安装')"
echo "  node:           $(_as_user bash -c 'node --version' 2>/dev/null || echo '未安装')"
echo "  npm:            $(_as_user bash -c 'npm --version' 2>/dev/null || echo '未安装')"
echo "  go:             $(_as_user bash -c 'go version' 2>/dev/null || echo '未安装')"
echo "  rustc:          $(_as_user bash -c 'rustc --version' 2>/dev/null || echo '未安装')"
echo "  cargo:          $(_as_user bash -c 'cargo --version' 2>/dev/null || echo '未安装')"
echo "  rust-analyzer:  $(_as_user bash -c 'rust-analyzer --version' 2>/dev/null || echo '未安装')"
echo "  gofumpt:        $(_as_user bash -c 'gofumpt -version' 2>/dev/null || echo '未安装')"
echo "  goimports:      $(_as_user bash -c 'command -v goimports' &>/dev/null && echo '已安装' || echo '未安装')"
echo "  prettier:       $(_as_user bash -c 'prettier --version' 2>/dev/null || echo '未安装')"

echo "[${EXTENSION_NAME}] 安装完成（请重新登录或 exec zsh 以刷新 PATH）"
