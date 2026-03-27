#cloud-config

hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

# 禁止密码登录，仅允许 SSH 密钥认证
ssh_pwauth: false

timezone: Asia/Shanghai

# Redirect all cloud-init output to both log file AND serial console
# so `virsh console` can show real-time progress
output:
  all: '| tee -a /var/log/cloud-init-output.log /dev/console'

# Enable serial console output in GRUB for future boots
bootcmd:
  - [sh, -c, 'test -f /etc/default/grub && grep -q "console=ttyS0" /etc/default/grub || (sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty1 console=ttyS0,115200 /" /etc/default/grub && update-grub)']

package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - apt-transport-https
  - software-properties-common
  - qemu-guest-agent

write_files:
  # Chrome + Xpra 安装脚本，用于宿主机无缝窗口转发
  - path: /opt/setup-chrome.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -euo pipefail

      echo "[Chrome 1/5] 添加 Google Chrome 官方 APT 源..."
      curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list

      echo "[Chrome 2/5] 添加 Xpra 官方 APT 源（避免与宿主机版本不兼容）..."
      curl -fsSL https://xpra.org/xpra.asc \
        -o /usr/share/keyrings/xpra.asc
      CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/xpra.list

      echo "[Chrome 3/5] 更新 APT 索引..."
      apt-get update -qq

      echo "[Chrome 4/5] 安装 Chrome、Xpra 及相关依赖..."
      apt-get install -y -qq \
        google-chrome-stable \
        xpra \
        xauth \
        dbus-x11 \
        fonts-noto-cjk

      echo "[Chrome 5/5] Chrome + Xpra 安装完成"
      google-chrome-stable --version
      xpra --version

  - path: /opt/setup-docker.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -euo pipefail

      echo "[1/4] Adding Docker GPG key..."
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc

      echo "[2/4] Adding Docker repository..."
      ARCH=$(dpkg --print-architecture)
      CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
      echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

      echo "[3/4] Installing Docker Engine..."
      apt-get update -qq
      apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

      echo "[4/4] Enabling Docker service..."
      systemctl enable --now docker
      usermod -aG docker ${VM_USER}

      echo "Docker installation complete."
      docker --version
      docker compose version

runcmd:
  - systemctl enable --now qemu-guest-agent
  - bash /opt/setup-docker.sh
  - bash /opt/setup-chrome.sh
  - echo "CLOUDINIT_SETUP_COMPLETE" > /var/log/cloud-init-done.log

final_message: "Cloud-init completed. System uptime: $UPTIME"
