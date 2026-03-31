#!/bin/bash
# Extension: example
# Description: 扩展脚本示例模板 — 复制此文件并修改来创建新扩展
#
# 使用方法：
#   1. 复制此文件：cp extensions/20-example.sh extensions/30-my-app.sh
#   2. 修改脚本内容，替换下方的安装逻辑
#   3. 运行 <APP_NAME> provision 将自动执行新扩展
#
# 命名规范：
#   - 格式：NN-name.sh（NN 为两位数字，控制执行顺序）
#   - 建议：10-29 基础设施，30-49 开发工具，50-69 业务应用，70+ 自定义
#
# 跳过与重跑机制（由 provision 统一管理，脚本无需处理）：
#   - provision 在执行前会计算脚本的 SHA-256 哈希
#   - 与 VM 上 /opt/kvm-extensions/<name>.done 中存储的哈希比较
#   - 哈希一致 → 自动跳过，不执行脚本
#   - 哈希不同或 .done 不存在 → 执行脚本，成功后写入新哈希
#   - 因此：修改脚本内容后再次 provision 会自动重跑
#
# 注意事项：
#   - 脚本以 root 权限运行
#   - 脚本变更后会自动重跑，开发者须自行保证幂等性
#   - 可在脚本内部做细粒度的幂等检查（如 command -v / dpkg -l 等）
set -euo pipefail

EXTENSION_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"

echo "[${EXTENSION_NAME}] 开始安装..."

# ============================================================
# 在此编写安装逻辑，例如：
#
#   apt-get update -qq
#   apt-get install -y -qq your-package
#
# 或安装 .deb 包：
#
#   curl -fsSL https://example.com/app.deb -o /tmp/app.deb
#   dpkg -i /tmp/app.deb || apt-get install -f -y
#   rm -f /tmp/app.deb
#
# ============================================================

echo "[${EXTENSION_NAME}] 此为示例扩展，无实际安装操作"

echo "[${EXTENSION_NAME}] 安装完成"
