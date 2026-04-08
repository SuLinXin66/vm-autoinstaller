#!/bin/bash
# Extension: locale-fonts
# Description: 配置中文 locale 和 CJK 字体，为所有需要中文支持的应用提供基础环境
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

echo "[${EXTENSION_NAME}] 配置中文环境..."

echo "[1/3] 安装 locales 和 CJK 字体..."
apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" locales fonts-noto-cjk

echo "[2/4] 生成 zh_CN.UTF-8 locale..."
sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen zh_CN.UTF-8

echo "[3/4] 设置系统默认 locale..."
update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

echo "[4/4] 验证..."
locale -a | grep zh_CN || echo "警告: zh_CN locale 生成可能失败"

echo "[${EXTENSION_NAME}] 中文环境配置完成"
