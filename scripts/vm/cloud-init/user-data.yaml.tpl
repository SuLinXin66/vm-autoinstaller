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

apt:
  conf: |
    Dpkg::Options {
      "--force-confdef";
      "--force-confold";
    };
    APT::Get::Assume-Yes "true";

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
  - path: /opt/setup-docker.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      export NEEDRESTART_MODE=a

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
  - export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a && bash /opt/setup-docker.sh
  - echo "CLOUDINIT_SETUP_COMPLETE" > /var/log/cloud-init-done.log

final_message: "Cloud-init completed. System uptime: $UPTIME"
