#!/bin/bash
# Extension: zsh-ohmyzsh
# Description: 安装 zsh + oh-my-zsh + oh-my-posh + 常用插件 + fzf + eza + neovim + fastfetch
#              + lazygit + yazi + neovim 编译依赖，并将 VM 用户默认 shell 设为 zsh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

VM_USER="${VM_USER:-$(getent passwd 1000 | cut -d: -f1)}"
USER_HOME="$(eval echo "~${VM_USER}")"
ARCH="$(dpkg --print-architecture)"

echo "[${EXTENSION_NAME}] 开始安装 zsh 终端环境..."

# ── 1. 系统包 ──────────────────────────────────────────────
echo "[1/10] 安装系统包..."
apt-get update -q
apt-get install -y -q \
    zsh fzf git curl unzip \
    ripgrep fd-find \
    luarocks gcc make \
    python3-venv

# fd-find 在 Ubuntu 上二进制名为 fdfind，创建 fd 软链接
if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    ln -s "$(command -v fdfind)" /usr/local/bin/fd
fi

# neovim: apt 版本过旧（< 0.10），LazyVim 需要 >= 0.10，从 GitHub Release 安装
echo "  安装 neovim（GitHub Release）..."
if ! nvim --version 2>/dev/null | head -1 | grep -qE 'v0\.(1[0-9]|[2-9][0-9])'; then
    _nvim_arch="x86_64"
    [[ "$ARCH" == "arm64" ]] && _nvim_arch="aarch64"
    curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${_nvim_arch}.tar.gz" \
        | tar xz -C /opt/
    ln -sf "/opt/nvim-linux-${_nvim_arch}/bin/nvim" /usr/local/bin/nvim
fi

# eza（Ubuntu 24.04 universe）
if ! command -v eza &>/dev/null; then
    apt-get install -y -q eza 2>/dev/null || {
        echo "  eza 不在默认仓库，通过 cargo-binstall 安装..."
        curl -fsSL https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-x86_64-unknown-linux-musl.tgz \
            | tar xz -C /usr/local/bin/
        cargo-binstall --no-confirm eza 2>/dev/null || echo "  警告: eza 安装失败，ls alias 将不可用"
    }
fi

# fastfetch
if ! command -v fastfetch &>/dev/null; then
    apt-get install -y -q fastfetch 2>/dev/null || {
        echo "  fastfetch 不在默认仓库，通过 PPA 安装..."
        add-apt-repository -y ppa:zhangsongcui3371/fastfetch 2>/dev/null || true
        apt-get update -q
        apt-get install -y -q fastfetch 2>/dev/null || echo "  警告: fastfetch 安装失败"
    }
fi

# ── 2. lazygit（GitHub Release） ───────────────────────────
echo "[2/10] 安装 lazygit..."
if ! command -v lazygit &>/dev/null; then
    LAZYGIT_VERSION="$(curl -fsSI https://github.com/jesseduffield/lazygit/releases/latest 2>/dev/null | grep -i '^location:' | sed -E 's|.*/v([^[:space:]]+).*|\1|')"
    if [[ -n "$LAZYGIT_VERSION" ]]; then
        _lg_arch="$ARCH"
        [[ "$_lg_arch" == "amd64" ]] && _lg_arch="x86_64"
        [[ "$_lg_arch" == "arm64" ]] && _lg_arch="arm64"
        curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${_lg_arch}.tar.gz" \
            | tar xz -C /usr/local/bin lazygit
        echo "  lazygit ${LAZYGIT_VERSION} 已安装"
    else
        echo "  警告: 无法获取 lazygit 最新版本号"
    fi
fi

# ── 3. yazi（GitHub Release） ──────────────────────────────
echo "[3/10] 安装 yazi..."
if ! command -v yazi &>/dev/null; then
    YAZI_VERSION="$(curl -fsSI https://github.com/sxyazi/yazi/releases/latest 2>/dev/null | grep -i '^location:' | sed -E 's|.*/v([^[:space:]]+).*|\1|')"
    if [[ -n "$YAZI_VERSION" ]]; then
        _yazi_arch="x86_64"
        [[ "$ARCH" == "arm64" ]] && _yazi_arch="aarch64"
        _yazi_url="https://github.com/sxyazi/yazi/releases/download/v${YAZI_VERSION}/yazi-${_yazi_arch}-unknown-linux-musl.zip"
        _tmp_yazi="$(mktemp -d)"
        curl -fsSL "$_yazi_url" -o "${_tmp_yazi}/yazi.zip"
        unzip -q "${_tmp_yazi}/yazi.zip" -d "$_tmp_yazi"
        install -m 755 "${_tmp_yazi}"/yazi-*/yazi /usr/local/bin/yazi
        install -m 755 "${_tmp_yazi}"/yazi-*/ya /usr/local/bin/ya 2>/dev/null || true
        rm -rf "$_tmp_yazi"
        echo "  yazi ${YAZI_VERSION} 已安装"
    else
        echo "  警告: 无法获取 yazi 最新版本号"
    fi
fi

# ── 4. oh-my-zsh ──────────────────────────────────────────
echo "[4/10] 安装 oh-my-zsh..."
OMZ_DIR="${USER_HOME}/.oh-my-zsh"
if [[ ! -d "$OMZ_DIR" ]]; then
    sudo -u "$VM_USER" bash -c \
        'export RUNZSH=no CHSH=no; curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | bash' \
        || true
fi

# ── 5. oh-my-zsh 第三方插件 ────────────────────────────────
echo "[5/10] 安装 oh-my-zsh 第三方插件..."
ZSH_CUSTOM="${OMZ_DIR}/custom"

_clone_plugin() {
    local repo="$1" dest="${ZSH_CUSTOM}/plugins/$2"
    if [[ ! -d "$dest" ]]; then
        sudo -u "$VM_USER" git clone --depth 1 "$repo" "$dest"
    fi
}

_clone_plugin "https://github.com/zsh-users/zsh-autosuggestions.git" "zsh-autosuggestions"
_clone_plugin "https://github.com/zdharma-continuum/fast-syntax-highlighting.git" "fast-syntax-highlighting"

# ── 6. oh-my-posh ─────────────────────────────────────────
echo "[6/10] 安装 oh-my-posh..."
_POSH_BIN="${USER_HOME}/.local/bin/oh-my-posh"
if [[ ! -x "$_POSH_BIN" ]]; then
    # 显式设置 HOME 确保安装到用户目录，而非 root 的 HOME
    sudo -u "$VM_USER" bash -c \
        "export HOME='${USER_HOME}'; mkdir -p '${USER_HOME}/.local/bin'; curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d '${USER_HOME}/.local/bin'" \
        || true
fi

# ── 7. neovim 配置 ────────────────────────────────────────
echo "[7/10] 克隆 neovim 配置..."
NVIM_CONFIG="${USER_HOME}/.config/nvim"
if [[ ! -d "$NVIM_CONFIG" ]]; then
    sudo -u "$VM_USER" mkdir -p "${USER_HOME}/.config"
    sudo -u "$VM_USER" git clone https://github.com/SuLinXin66/nvim-config.git "$NVIM_CONFIG" || true
fi

# ── 8. 确保 ~/.local/bin 在 PATH 中（oh-my-posh 安装在此）──
echo "[8/10] 配置 PATH..."
_PROFILE="${USER_HOME}/.profile"
if ! grep -q '.local/bin' "$_PROFILE" 2>/dev/null; then
    sudo -u "$VM_USER" bash -c "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> '$_PROFILE'"
fi

# ── 9. 设置默认 shell ─────────────────────────────────────
echo "[9/10] 设置默认 shell 为 zsh..."
chsh -s "$(command -v zsh)" "$VM_USER"

# ── 10. 验证 ─────────────────────────────────────────────
echo "[10/10] 验证安装..."
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
