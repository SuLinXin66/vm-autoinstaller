#!/bin/bash
# Extension: chrome-xpra
# Description: 安装 Chrome 浏览器和 Xpra 远程显示服务，用于宿主机无缝窗口转发
set -euo pipefail

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

echo "[${EXTENSION_NAME}] 开始安装 Chrome + Xpra..."

echo "[1/5] 添加 Google Chrome 官方 APT 源..."
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/google-chrome.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list

echo "[2/5] 添加 Xpra 官方 APT 源（避免与宿主机版本不兼容）..."
curl -fsSL https://xpra.org/xpra.asc \
    -o /usr/share/keyrings/xpra.asc
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org/ ${CODENAME} main" \
    > /etc/apt/sources.list.d/xpra.list

echo "[3/5] 更新 APT 索引..."
apt-get update -q

echo "[4/5] 安装 Chrome、Xpra 及相关依赖..."
# xpra-html5: Windows 宿主机通过浏览器访问时需要 HTML5 客户端
# xvfb: X11 forwarding 模式（VcXsrv）需要虚拟帧缓冲
apt-get install -y -q \
    google-chrome-stable \
    xpra \
    xpra-html5 \
    xauth \
    xvfb \
    dbus-x11

echo "[5/5] 验证安装..."
google-chrome-stable --version
xpra --version

echo "[${EXTENSION_NAME}] 安装完成"
