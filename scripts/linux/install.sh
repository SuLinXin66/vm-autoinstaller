#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

# Load libraries
source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/sudo.sh"
source "${PROJECT_ROOT}/lib/sys.sh"
source "${PROJECT_ROOT}/lib/pkg.sh"
source "${PROJECT_ROOT}/lib/utils.sh"
source "${PROJECT_ROOT}/lib/vm.sh"

# Load configuration
if [[ ! -f "${REPO_ROOT}/vm/config.env" ]]; then
    log::die "配置文件 config.env 不存在，请先复制模板：cp vm/config.env.example vm/config.env"
fi
source "${REPO_ROOT}/vm/config.env"

# Allow environment variable overrides
VM_NAME="${VM_NAME:-ubuntu-server}"
VM_CPUS="${VM_CPUS:-0}"
if [[ "$VM_CPUS" == "0" || -z "$VM_CPUS" ]]; then
    VM_CPUS="$(nproc)"
fi
VM_MEMORY="${VM_MEMORY:-2048}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20}"
VM_USER="${VM_USER:-wpsweb}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
NETWORK_MODE="${NETWORK_MODE:-nat}"
BRIDGE_NAME="${BRIDGE_NAME:-br0}"
DATA_DIR="${DATA_DIR:-${HOME}/.kvm-ubuntu}"
UBUNTU_IMAGE_BASE_URL="${UBUNTU_IMAGE_BASE_URL:-https://cloud-images.ubuntu.com/releases}"

# --- Derived paths ---
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  CLOUD_ARCH="amd64" ;;
    aarch64) CLOUD_ARCH="arm64" ;;
    *)       log::die "不支持的架构: ${ARCH}" ;;
esac

IMAGE_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-${CLOUD_ARCH}.img"
IMAGE_URL="${UBUNTU_IMAGE_BASE_URL}/${UBUNTU_VERSION}/release/${IMAGE_NAME}"
IMAGE_PATH="${DATA_DIR}/${IMAGE_NAME}"
DISK_PATH="${DATA_DIR}/${VM_NAME}.qcow2"
SEED_ISO="${DATA_DIR}/${VM_NAME}-seed.iso"
USER_DATA="${DATA_DIR}/user-data.yaml"

# --- CLI argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)   AUTO_YES=1; shift ;;
        -h|--help)
            echo "用法: $0 [-y|--yes] [-h|--help]"
            echo ""
            echo "选项:"
            echo "  -y, --yes    跳过确认提示，自动执行"
            echo "  -h, --help   显示帮助信息"
            echo ""
            echo "配置: 编辑 config.env 或通过环境变量覆盖"
            exit 0
            ;;
        *)
            log::die "未知参数: $1 (使用 -h 查看帮助)"
            ;;
    esac
done

# ====================================================================
# Main installation flow
# ====================================================================

TOTAL_STEPS=7
log::set_total_steps "$TOTAL_STEPS"

log::banner "KVM Ubuntu Server 自动化安装"

echo "  VM 名称:    ${VM_NAME}"
echo "  CPU:        ${VM_CPUS} 核"
echo "  内存:       ${VM_MEMORY} MB"
echo "  磁盘:       ${VM_DISK_SIZE} GB"
echo "  用户名:     ${VM_USER}"
echo "  Ubuntu:     ${UBUNTU_VERSION}"
echo "  网络模式:   ${NETWORK_MODE}"
echo "  数据目录:   ${DATA_DIR}"
echo ""

if ! utils::confirm "确认以上配置并开始安装?"; then
    log::info "已取消"
    exit 0
fi

# --- Step 1: Validate sudo ---
log::step "验证权限"
sudo::ensure

# --- Step 2: System checks ---
log::step "系统环境检测"

distro="$(sys::detect_distro)"
arch="$(sys::detect_arch)"
log::info "检测到系统: ${distro} (${arch})"

sys::check_kvm

# --- Step 3: Install host dependencies ---
log::step "安装宿主机依赖"

REQUIRED_PKGS=(
    qemu-kvm
    libvirt
    virt-install
    cloud-image-utils
    wget
    qemu-img
    libvirt-client
    dnsmasq
)

need_install=()
for p in "${REQUIRED_PKGS[@]}"; do
    if ! pkg::is_installed "$p"; then
        need_install+=("$p")
    fi
done

if [[ ${#need_install[@]} -gt 0 ]]; then
    pkg::update
    pkg::install "${need_install[@]}"
    log::ok "依赖安装完成"
else
    log::ok "所有依赖已就绪"
fi

# Ensure libvirtd is running after package install
sys::check_libvirt
sys::ensure_user_in_libvirt

# Ensure default network is active (LANG=C for consistent output parsing)
if ! sudo::exec env LC_ALL=C virsh net-info default &>/dev/null; then
    log::info "创建默认虚拟网络..."
    sudo::exec virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
    sudo::exec virsh net-start default 2>/dev/null || true
    sudo::exec virsh net-autostart default 2>/dev/null || true
elif ! sudo::exec env LC_ALL=C virsh net-info default 2>/dev/null | grep -q "Active:.*yes"; then
    log::info "启动默认虚拟网络..."
    sudo::exec virsh net-start default 2>/dev/null || true
    sudo::exec virsh net-autostart default 2>/dev/null || true
fi

# Ensure firewall allows virbr0 traffic (DHCP etc.)
sys::ensure_bridge_firewall virbr0

# --- Step 4: Download cloud image ---
log::step "下载 Ubuntu Cloud Image"

mkdir -p "$DATA_DIR"
utils::download "$IMAGE_URL" "$IMAGE_PATH" "Ubuntu ${UBUNTU_VERSION} Cloud Image"

# --- Step 5: Prepare VM disk and cloud-init ---
log::step "准备 VM 磁盘与 cloud-init"

if vm::exists "$VM_NAME"; then
    log::warn "VM [${VM_NAME}] 已存在"
    if ! utils::confirm "是否销毁现有 VM 并重新创建?"; then
        log::info "已取消"
        exit 0
    fi
    vm::destroy "$VM_NAME" "$DATA_DIR"
fi

# Create VM disk (backed by cloud image)
vm::create_disk "$IMAGE_PATH" "$DISK_PATH" "$VM_DISK_SIZE"

# Generate SSH key pair for automated access
SSH_KEY_PATH="${DATA_DIR}/id_ed25519"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
    log::ok "SSH 密钥对已生成: ${SSH_KEY_PATH}"
fi
SSH_PUBLIC_KEY="$(cat "${SSH_KEY_PATH}.pub")"

# Render cloud-init template
log::info "生成 cloud-init 配置..."
export VM_NAME VM_USER SSH_PUBLIC_KEY
envsubst '${VM_NAME} ${VM_USER} ${SSH_PUBLIC_KEY}' \
    < "${REPO_ROOT}/vm/cloud-init/user-data.yaml.tpl" > "$USER_DATA"

# Create seed ISO
vm::create_seed_iso "$USER_DATA" "$SEED_ISO"

# --- Step 6: Create and start VM ---
log::step "创建并启动 VM"

net_arg="nat"
if [[ "$NETWORK_MODE" == "bridge" ]]; then
    net_arg="bridge:${BRIDGE_NAME}"
fi

vm::install "$VM_NAME" "$DISK_PATH" "$SEED_ISO" "$VM_CPUS" "$VM_MEMORY" "$net_arg"

# --- Step 7: Monitor VM setup ---
log::step "监控 VM 安装进度"

vm::set_ssh_key "$SSH_KEY_PATH"
if vm_ip="$(vm::wait_ready "$VM_NAME" "$VM_USER")"; then
    # cloud-init 完成后，执行扩展模块（Chrome/Xpra 等）
    log::info "开始执行扩展模块..."
    "${PROJECT_ROOT}/provision.sh" || log::warn "部分扩展模块执行失败，可稍后运行 ${APP_NAME} provision 重试"

    log::banner "安装完成"
    echo ""
    echo "  VM 已就绪！连接信息："
    echo ""
    echo "    SSH:     ssh -i ${SSH_KEY_PATH} ${VM_USER}@${vm_ip}"
    echo "    密钥:    ${SSH_KEY_PATH}"
    echo ""
    echo "  快捷命令："
    echo "    ${APP_NAME} ssh           SSH 连入 VM"
    echo "    ${APP_NAME} chrome        启动 Chrome 浏览器"
    echo "    ${APP_NAME} status        查看 VM 状态"
    echo "    ${APP_NAME} destroy       销毁 VM"
    echo ""
else
    log::warn "VM 安装过程中出现问题"
    log::info "你可以手动检查:"
    log::info "  virsh console ${VM_NAME}"
    log::info "  ${APP_NAME} status"
fi
