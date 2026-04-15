#!/bin/bash
# Extension: zsh-ohmyzsh
# Description: 安装 zsh + oh-my-zsh + oh-my-posh + 常用插件 + fzf + eza + neovim + fastfetch
#              + lazygit + yazi + neovim 编译依赖，并将 VM 用户默认 shell 设为 zsh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

source /opt/kvm-extensions/lib/net.sh
source /opt/kvm-extensions/lib/pkg.sh
net::init_proxy

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

VM_USER="${VM_USER:-$(getent passwd 1000 | cut -d: -f1)}"
USER_HOME="$(eval echo "~${VM_USER}")"
ARCH="$(dpkg --print-architecture)"

echo "[${EXTENSION_NAME}] 开始安装 zsh 终端环境..."

# ── 1. 系统包 ──────────────────────────────────────────────
echo "[1/10] 安装系统包..."
pkg::apt_update
apt-get install -y -q \
    zsh fzf git curl unzip \
    ripgrep fd-find \
    luarocks gcc make \
    python3-venv \
    ncurses-term

# fd-find 在 Ubuntu 上二进制名为 fdfind，创建 fd 软链接
if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    ln -s "$(command -v fdfind)" /usr/local/bin/fd
fi

# 现代终端 terminfo：ncurses-term 覆盖 alacritty/tmux/foot 等，
# 以下为不在 ncurses-term 中的终端补充 terminfo（基于 xterm-256color）
_modern_terms=(xterm-kitty xterm-ghostty)
for _mt in "${_modern_terms[@]}"; do
    if ! infocmp "$_mt" &>/dev/null 2>&1; then
        printf '%s|%s terminal,\n\tuse=xterm-256color,\n' "$_mt" "$_mt" | tic -x - 2>/dev/null || true
    fi
done

# neovim: apt 版本过旧（< 0.10），LazyVim 需要 >= 0.10，从 GitHub Release 安装
echo "  安装 neovim（GitHub Release）..."
if ! nvim --version 2>/dev/null | head -1 | grep -qE 'v0\.(1[0-9]|[2-9][0-9])'; then
    _nvim_arch="x86_64"
    [[ "$ARCH" == "arm64" ]] && _nvim_arch="aarch64"
    _tmp_nvim="$(mktemp)"
    if net::download "$(net::ghurl "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${_nvim_arch}.tar.gz")" "$_tmp_nvim"; then
        tar xzf "$_tmp_nvim" -C /opt/
        ln -sf "/opt/nvim-linux-${_nvim_arch}/bin/nvim" /usr/local/bin/nvim
    else
        echo "  警告: neovim 下载失败"
    fi
    rm -f "$_tmp_nvim"
fi

# eza（Ubuntu 24.04 universe）
if ! command -v eza &>/dev/null; then
    apt-get install -y -q eza 2>/dev/null || {
        echo "  eza 不在默认仓库，通过 cargo-binstall 安装..."
        _tmp_cb="$(mktemp)"
        if net::download "$(net::ghurl "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-x86_64-unknown-linux-musl.tgz")" "$_tmp_cb"; then
            tar xzf "$_tmp_cb" -C /usr/local/bin/
            cargo-binstall --no-confirm eza 2>/dev/null || echo "  警告: eza 安装失败，ls alias 将不可用"
        else
            echo "  警告: cargo-binstall 下载失败"
        fi
        rm -f "$_tmp_cb"
    }
fi

# fastfetch
if ! command -v fastfetch &>/dev/null; then
    apt-get install -y -q fastfetch 2>/dev/null || {
        echo "  fastfetch 不在默认仓库，通过 PPA 安装..."
        add-apt-repository -y ppa:zhangsongcui3371/fastfetch 2>/dev/null || true
        pkg::apt_update --force
        apt-get install -y -q fastfetch 2>/dev/null || echo "  警告: fastfetch 安装失败"
    }
fi

# ── 2. lazygit（GitHub Release） ───────────────────────────
echo "[2/10] 安装 lazygit..."
if ! command -v lazygit &>/dev/null; then
    LAZYGIT_VERSION="$(net::ghlatest "$(net::ghurl "https://github.com/jesseduffield/lazygit/releases/latest")")"
    if [[ -n "$LAZYGIT_VERSION" ]]; then
        _lg_arch="$ARCH"
        [[ "$_lg_arch" == "amd64" ]] && _lg_arch="x86_64"
        [[ "$_lg_arch" == "arm64" ]] && _lg_arch="arm64"
        _tmp_lg="$(mktemp)"
        if net::download "$(net::ghurl "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${_lg_arch}.tar.gz")" "$_tmp_lg"; then
            tar xzf "$_tmp_lg" -C /usr/local/bin lazygit
            echo "  lazygit ${LAZYGIT_VERSION} 已安装"
        else
            echo "  警告: lazygit 下载失败"
        fi
        rm -f "$_tmp_lg"
    else
        echo "  警告: 无法获取 lazygit 最新版本号"
    fi
fi

# ── 3. yazi（GitHub Release） ──────────────────────────────
echo "[3/10] 安装 yazi..."
if ! command -v yazi &>/dev/null; then
    YAZI_VERSION="$(net::ghlatest "$(net::ghurl "https://github.com/sxyazi/yazi/releases/latest")")"
    if [[ -n "$YAZI_VERSION" ]]; then
        _yazi_arch="x86_64"
        [[ "$ARCH" == "arm64" ]] && _yazi_arch="aarch64"
        _tmp_yazi="$(mktemp -d)"
        if net::download "$(net::ghurl "https://github.com/sxyazi/yazi/releases/download/v${YAZI_VERSION}/yazi-${_yazi_arch}-unknown-linux-musl.zip")" "${_tmp_yazi}/yazi.zip"; then
            unzip -q "${_tmp_yazi}/yazi.zip" -d "$_tmp_yazi"
            install -m 755 "${_tmp_yazi}"/yazi-*/yazi /usr/local/bin/yazi
            install -m 755 "${_tmp_yazi}"/yazi-*/ya /usr/local/bin/ya 2>/dev/null || true
            echo "  yazi ${YAZI_VERSION} 已安装"
        else
            echo "  警告: yazi 下载失败"
        fi
        rm -rf "$_tmp_yazi"
    else
        echo "  警告: 无法获取 yazi 最新版本号"
    fi
fi

# ── 4. oh-my-zsh ──────────────────────────────────────────
echo "[4/10] 安装 oh-my-zsh..."
OMZ_DIR="${USER_HOME}/.oh-my-zsh"
if [[ ! -d "$OMZ_DIR" ]]; then
    # 直接 clone（而非 curl|bash），完全控制 git 操作的代理和重试
    if net::ghclone "$(net::ghurl "https://github.com/ohmyzsh/ohmyzsh.git")" "$OMZ_DIR" "$VM_USER"; then
        # 复制模板 .zshrc（与官方安装脚本行为一致）
        if [[ -f "${OMZ_DIR}/templates/zshrc.zsh-template" && ! -f "${USER_HOME}/.zshrc" ]]; then
            sudo -u "$VM_USER" cp "${OMZ_DIR}/templates/zshrc.zsh-template" "${USER_HOME}/.zshrc"
        fi
    fi
fi

# ── 5. oh-my-zsh 第三方插件 ────────────────────────────────
echo "[5/10] 安装 oh-my-zsh 第三方插件..."
ZSH_CUSTOM="${OMZ_DIR}/custom"

_clone_plugin() {
    local repo="$1" dest="${ZSH_CUSTOM}/plugins/$2"
    if [[ ! -d "$dest" ]]; then
        net::ghclone "$repo" "$dest" "$VM_USER" || true
    fi
}

_clone_plugin "$(net::ghurl "https://github.com/zsh-users/zsh-autosuggestions.git")" "zsh-autosuggestions"
_clone_plugin "$(net::ghurl "https://github.com/zdharma-continuum/fast-syntax-highlighting.git")" "fast-syntax-highlighting"

# ── 6. oh-my-posh ─────────────────────────────────────────
echo "[6/10] 安装 oh-my-posh..."
_POSH_BIN="${USER_HOME}/.local/bin/oh-my-posh"
if [[ ! -x "$_POSH_BIN" ]]; then
    _posh_script="$(mktemp)"
    if net::download "https://ohmyposh.dev/install.sh" "$_posh_script"; then
        sudo -u "$VM_USER" bash -c \
            "export HOME='${USER_HOME}'; mkdir -p '${USER_HOME}/.local/bin'; bash '${_posh_script}' -d '${USER_HOME}/.local/bin'" \
            || true
    fi
    rm -f "$_posh_script"
fi

# ── 7. neovim 配置 ────────────────────────────────────────
echo "[7/11] 克隆 neovim 配置..."
NVIM_CONFIG="${USER_HOME}/.config/nvim"
if [[ ! -d "$NVIM_CONFIG" ]]; then
    sudo -u "$VM_USER" mkdir -p "${USER_HOME}/.config"
    net::ghclone "$(net::ghurl "https://github.com/SuLinXin66/nvim-config.git")" "$NVIM_CONFIG" "$VM_USER" || true
fi

# ── 8. neovim 插件同步（headless） ───────────────────────
echo "[8/11] 同步 neovim 插件（LazyVim headless sync）..."

if [[ -d "$NVIM_CONFIG" ]] && command -v nvim &>/dev/null; then
    _nvim_sync_ok=false
    _nvim_env="export HOME='${USER_HOME}' PATH='/usr/local/bin:/usr/bin:/bin'"
    _nvim_preserve_env="http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,no_proxy"

    if [[ -n "${http_proxy:-}" ]]; then
        echo "  使用 HTTP 代理: ${http_proxy}"
    fi

    echo "  [1/3] Lazy sync..."
    if sudo --preserve-env="${_nvim_preserve_env}" \
            -u "$VM_USER" bash -c "${_nvim_env}; nvim --headless '+Lazy! sync' '+qa' 2>&1" 2>&1 | sed 's/^/    /'; then
        echo "  [2/3] TSUpdate..."
        sudo --preserve-env="${_nvim_preserve_env}" \
            -u "$VM_USER" bash -c "${_nvim_env}; nvim --headless '+TSUpdate' '+qa' 2>&1" 2>&1 | sed 's/^/    /' || true

        echo "  [3/3] Mason install..."
        sudo --preserve-env="${_nvim_preserve_env}" \
            -u "$VM_USER" bash -c "${_nvim_env}; nvim --headless '+lua require(\"mason-registry\").refresh()' '+MasonInstallAll' '+sleep 30' '+qa' 2>&1" 2>&1 | sed 's/^/    /' || true

        _nvim_sync_ok=true
    fi

    if [[ "$_nvim_sync_ok" == "true" ]]; then
        echo "  neovim 插件同步完成"
    else
        echo ""
        echo "  ╔═════════════════════════════════════════════════════════════╗"
        echo "  ║  neovim 插件同步失败（可能是网络问题或超时）               ║"
        echo "  ║  可稍后 SSH 进入 VM 手动执行:                              ║"
        echo "  ║    nvim --headless '+Lazy! sync' '+qa'                     ║"
        echo "  ╚═════════════════════════════════════════════════════════════╝"
        echo ""
    fi
else
    echo "  跳过：nvim 或配置目录不存在"
fi

# ── 9. 确保 ~/.local/bin 在 PATH 中（oh-my-posh 安装在此）+ TERM 回退 ──
echo "[9/11] 配置 PATH 及终端兼容性..."
_PROFILE="${USER_HOME}/.profile"
if ! grep -q '.local/bin' "$_PROFILE" 2>/dev/null; then
    sudo -u "$VM_USER" bash -c "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> '$_PROFILE'"
fi

_ZSHRC="${USER_HOME}/.zshrc"
if ! grep -q 'TERM fallback' "$_ZSHRC" 2>/dev/null; then
    _term_block='# TERM fallback: SSH 进入时宿主机终端类型（如 xterm-kitty）可能在 VM 中无 terminfo
if ! infocmp "$TERM" &>/dev/null 2>&1; then
    export TERM=xterm-256color
fi
'
    _old="$(cat "$_ZSHRC")"
    printf '%s\n%s' "$_term_block" "$_old" | sudo -u "$VM_USER" tee "$_ZSHRC" > /dev/null
fi

# ── 10. 设置默认 shell ────────────────────────────────────
echo "[10/11] 设置默认 shell 为 zsh..."
chsh -s "$(command -v zsh)" "$VM_USER"

# ── 11. 验证 ──────────────────────────────────────────────
echo "[11/11] 验证安装..."
echo "  zsh:          $(zsh --version 2>/dev/null || echo '未安装')"
echo "  fzf:          $(fzf --version 2>/dev/null || echo '未安装')"
echo "  neovim:       $(nvim --version 2>/dev/null | head -1 || echo '未安装')"
echo "  eza:          $(eza --version 2>/dev/null | head -1 || echo '未安装')"
echo "  fastfetch:    $(fastfetch --version 2>/dev/null || echo '未安装')"
echo "  ripgrep:      $(rg --version 2>/dev/null | head -1 || echo '未安装')"
echo "  fd:           $(fd --version 2>/dev/null || echo '未安装')"
echo "  lazygit:      $(lazygit --version 2>/dev/null | head -1 || echo '未安装')"
echo "  yazi:         $(yazi --version 2>/dev/null || echo '未安装')"
echo "  luarocks:     $(luarocks --version 2>/dev/null | head -1 || echo '未安装')"
echo "  gcc:          $(gcc --version 2>/dev/null | head -1 || echo '未安装')"
echo "  oh-my-zsh:    $(test -d "$OMZ_DIR" && echo '已安装' || echo '未安装')"
echo "  oh-my-posh:   $(sudo -u "$VM_USER" bash -c "export HOME='${USER_HOME}' PATH='${USER_HOME}/.local/bin:\$PATH'; oh-my-posh --version 2>/dev/null" || echo '未安装')"

echo "[${EXTENSION_NAME}] 安装完成"
