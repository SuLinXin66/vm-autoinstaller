#!/bin/bash
# Extension: chrome-xpra
# Description: 安装 Chrome/Chromium 浏览器和 Xpra 远程显示服务，用于宿主机无缝窗口转发
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

source /opt/kvm-extensions/lib/net.sh
net::init_proxy

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
CN_MODE="${CN_MODE:-0}"

echo "[${EXTENSION_NAME}] 开始安装浏览器 + Xpra..."

if [[ "$CN_MODE" == "1" ]]; then
    echo "[1/5] CN_MODE=1，跳过 Google Chrome，将安装 Chromium..."
else
    echo "[1/5] 添加 Google Chrome 官方 APT 源..."
    _tmp_gpg="$(mktemp)"
    net::download "https://dl.google.com/linux/linux_signing_key.pub" "$_tmp_gpg"
    gpg --batch --yes --dearmor -o /usr/share/keyrings/google-chrome.gpg < "$_tmp_gpg"
    rm -f "$_tmp_gpg"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list
fi

echo "[2/5] 添加 Xpra 官方 APT 源（避免与宿主机版本不兼容）..."
net::download "https://xpra.org/xpra.asc" /usr/share/keyrings/xpra.asc
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org/ ${CODENAME} main" \
    > /etc/apt/sources.list.d/xpra.list

echo "[3/5] 更新 APT 索引..."
apt-get update -q

echo "[4/5] 安装浏览器、Xpra 及相关依赖..."
if [[ "$CN_MODE" == "1" ]]; then
    apt-get install -y -q \
        xpra \
        xpra-html5 \
        xauth \
        xvfb \
        dbus-x11

    # Ubuntu 24.04 的 chromium-browser 是 snap 过渡包，snap store 在国内基本不可用
    # 方案: 从 Debian 源安装真正的 chromium .deb（通过 USTC 镜像，国内极快）
    _chromium_ok=false
    _arch="$(dpkg --print-architecture)"

    echo "  从 Debian USTC 镜像安装 Chromium .deb（跳过 snap）..."

    # 获取 Debian 仓库签名密钥
    _deb_keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
    if [[ ! -f "$_deb_keyring" ]]; then
        apt-get install -y -q debian-archive-keyring 2>/dev/null || true
    fi

    # 如果 keyring 仍不存在，使用 trusted=yes 作为回退
    if [[ -f "$_deb_keyring" ]]; then
        _deb_signed="signed-by=${_deb_keyring}"
    else
        _deb_signed="trusted=yes"
    fi

    # 添加 Debian bookworm 源（仅用于 chromium），通过 USTC 镜像
    echo "deb [arch=${_arch} ${_deb_signed}] https://mirrors.ustc.edu.cn/debian/ bookworm main" \
        > /etc/apt/sources.list.d/debian-chromium.list

    # APT 优先级钉扎：仅允许 chromium 相关包从 Debian 安装，其余全部屏蔽
    cat > /etc/apt/preferences.d/debian-chromium.pref << 'PINEOF'
Package: *
Pin: release n=bookworm
Pin-Priority: -10

Package: chromium chromium-common chromium-sandbox chromium-l10n
Pin: release n=bookworm
Pin-Priority: 600
PINEOF

    apt-get update -q
    if apt-get install -y -q chromium; then
        _chromium_ok=true
        echo "  Chromium (Debian .deb) 安装成功"
    else
        echo "  Debian bookworm 版本有依赖冲突，尝试 trixie (testing)..."
        # 切换到 Debian trixie（与 Ubuntu 24.04 库版本更接近）
        echo "deb [arch=${_arch} ${_deb_signed}] https://mirrors.ustc.edu.cn/debian/ trixie main" \
            > /etc/apt/sources.list.d/debian-chromium.list
        sed -i 's/bookworm/trixie/g' /etc/apt/preferences.d/debian-chromium.pref
        apt-get update -q
        if apt-get install -y -q chromium; then
            _chromium_ok=true
            echo "  Chromium (Debian trixie .deb) 安装成功"
        fi
    fi

    # Debian 源安装失败后清理，然后尝试 Flatpak 兜底
    if [[ "$_chromium_ok" != "true" ]]; then
        rm -f /etc/apt/sources.list.d/debian-chromium.list /etc/apt/preferences.d/debian-chromium.pref
        apt-get update -q 2>/dev/null || true

        echo "  Debian 源安装失败，尝试通过 Flatpak 安装 Chromium..."
        apt-get install -y -q flatpak 2>/dev/null || true

        if command -v flatpak &>/dev/null; then
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
            # 国内使用 SJTU Flathub 镜像
            flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub 2>/dev/null || true

            if flatpak install -y flathub org.chromium.Chromium; then
                _chromium_ok=true
                # 允许 Flatpak Chromium 读取宿主策略文件（书签等）
                flatpak override --filesystem=/etc/chromium/policies/managed:ro org.chromium.Chromium 2>/dev/null || true
                echo "  Chromium (Flatpak) 安装成功"
            fi
        fi
    fi

    if [[ "$_chromium_ok" != "true" ]]; then
        echo ""
        echo "  ╔═════════════════════════════════════════════════════════════╗"
        echo "  ║  Chromium 安装失败（可稍后 SSH 进入 VM 手动安装）          ║"
        echo "  ║    sudo apt install -y flatpak                             ║"
        echo "  ║    flatpak remote-add --if-not-exists flathub \\            ║"
        echo "  ║      https://flathub.org/repo/flathub.flatpakrepo          ║"
        echo "  ║    flatpak install -y flathub org.chromium.Chromium        ║"
        echo "  ╚═════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Chromium 书签策略（不论安装方式，Chromium 均读取此路径）
    if [[ "$_chromium_ok" == "true" ]]; then
        mkdir -p /etc/chromium/policies/managed
    fi
else
    apt-get install -y -q \
        google-chrome-stable \
        xpra \
        xpra-html5 \
        xauth \
        xvfb \
        dbus-x11
    mkdir -p /etc/opt/chrome/policies/managed /etc/chromium/policies/managed
fi

echo "[5/5] 验证安装..."
if command -v google-chrome-stable &>/dev/null; then
    google-chrome-stable --version
elif command -v chromium &>/dev/null; then
    chromium --version
elif command -v chromium-browser &>/dev/null; then
    chromium-browser --version
elif flatpak list 2>/dev/null | grep -q org.chromium.Chromium; then
    echo "  Chromium (Flatpak) $(flatpak info org.chromium.Chromium 2>/dev/null | grep -i version | head -1 || echo 'installed')"
else
    echo "  警告: 未检测到 Chrome 或 Chromium"
fi
xpra --version

echo "[${EXTENSION_NAME}] 安装完成"
