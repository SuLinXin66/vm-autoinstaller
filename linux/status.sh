#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/vm.sh"
[[ -f "${REPO_ROOT}/vm/config.env" ]] || { echo "错误: config.env 不存在，请先 cp vm/config.env.example vm/config.env" >&2; exit 1; }
source "${REPO_ROOT}/vm/config.env"

VM_NAME="${VM_NAME:-ubuntu-server}"

log::banner "VM 状态: ${VM_NAME}"
vm::status "$VM_NAME"
