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
    # Debian bookworm/trixie 的 chromium .deb 在 Ubuntu 24.04 上必定依赖冲突
    # 直接通过 Flatpak 安装（使用 SJTU 镜像，国内速度好）
    _chromium_ok=false

    echo "  通过 Flatpak 安装 Chromium（SJTU 镜像）..."
    apt-get install -y -q flatpak 2>/dev/null || true

    if command -v flatpak &>/dev/null; then
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub 2>/dev/null || true

        if flatpak install -y flathub org.chromium.Chromium; then
            _chromium_ok=true
            flatpak override --filesystem=host-etc:ro org.chromium.Chromium 2>/dev/null || true
            echo "  Chromium (Flatpak) 安装成功"
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
