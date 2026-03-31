#!/bin/bash
# Extension: asdf
# Description: 按官方方式安装 asdf Go 二进制（GitHub Release latest），清理旧 bash 版仓库文件，生成 zsh 补全
set -euo pipefail

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

VM_USER="${VM_USER:-wpsweb}"
USER_HOME="$(eval echo "~${VM_USER}")"
ASDF_DATA="${USER_HOME}/.asdf"
LOCAL_BIN="${USER_HOME}/.local/bin"

echo "[${EXTENSION_NAME}] 安装 asdf（官方预编译二进制）..."

apt-get install -y -q curl ca-certificates git

sudo -u "$VM_USER" mkdir -p "$LOCAL_BIN"

# ── 解析 latest 版本号（与 lazygit/yazi 扩展一致：用 Location 头，避免 GitHub API 未认证 403 + curl -f 直接失败）──
ASDF_VER="$(curl -fsSI --connect-timeout 15 https://github.com/asdf-vm/asdf/releases/latest 2>/dev/null \
    | grep -i '^location:' | sed -E 's|.*/v([^[:space:]]+).*|\1|' | tr -d '\r')"
if [[ -z "$ASDF_VER" ]]; then
    echo "  警告: 无法从 releases/latest 解析版本，使用 0.18.1"
    ASDF_VER="0.18.1"
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64) ASDF_ARCH="amd64" ;;
    arm64) ASDF_ARCH="arm64" ;;
    i386)  ASDF_ARCH="386" ;;
    *) echo "  错误: 不支持的架构: $ARCH"; exit 1 ;;
esac

ASDF_TGZ="asdf-v${ASDF_VER}-linux-${ASDF_ARCH}.tar.gz"
ASDF_URL="https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VER}/${ASDF_TGZ}"

echo "[1/4] 下载 ${ASDF_TGZ} ..."
_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
if ! curl -fsSL --connect-timeout 30 "$ASDF_URL" -o "${_tmp}/asdf.tgz"; then
    echo "  错误: 下载失败: $ASDF_URL"
    exit 1
fi
tar xzf "${_tmp}/asdf.tgz" -C "$_tmp"
if [[ ! -f "${_tmp}/asdf" ]]; then
    echo "  错误: 压缩包内未找到 asdf 可执行文件"
    exit 1
fi
install -m 755 "${_tmp}/asdf" "${LOCAL_BIN}/asdf"
chown "$VM_USER:$VM_USER" "${LOCAL_BIN}/asdf"

# ── 清理旧 bash 版克隆（保留 plugins / installs / downloads / shims 等数据）──
if [[ -f "${ASDF_DATA}/asdf.sh" ]]; then
    echo "[2/4] 清理旧 bash 版 asdf 仓库文件..."
    rm -rf "${ASDF_DATA}/.git" "${ASDF_DATA}/bin" "${ASDF_DATA}/lib" "${ASDF_DATA}/test" "${ASDF_DATA}/docs" 2>/dev/null || true
    rm -f "${ASDF_DATA}/asdf.sh" "${ASDF_DATA}/Makefile" 2>/dev/null || true
fi
echo "[3/4] 生成 zsh 补全 _asdf ..."
sudo -u "$VM_USER" mkdir -p "${ASDF_DATA}/completions"
if ! sudo -u "$VM_USER" env HOME="$USER_HOME" PATH="${LOCAL_BIN}:${PATH}" ASDF_DATA_DIR="$ASDF_DATA" \
    bash -c 'command asdf completion zsh > "${ASDF_DATA_DIR}/completions/_asdf"'; then
    echo "  警告: asdf completion zsh 失败，可登录后执行: asdf completion zsh > ~/.asdf/completions/_asdf"
fi

echo "[4/4] 验证与 reshim ..."
VER_OUT="$(sudo -u "$VM_USER" env HOME="$USER_HOME" PATH="${LOCAL_BIN}:${PATH}" ASDF_DATA_DIR="$ASDF_DATA" \
    bash -c 'command asdf --version' 2>/dev/null || echo '未知')"
echo "  asdf: ${VER_OUT}"

sudo -u "$VM_USER" env HOME="$USER_HOME" PATH="${LOCAL_BIN}:${PATH}" ASDF_DATA_DIR="$ASDF_DATA" \
    bash -c 'command asdf reshim' 2>/dev/null || true

echo "[${EXTENSION_NAME}] 安装完成（请重新登录或 exec zsh；若补全仍无刷新可 rm ~/.zcompdump*）"
