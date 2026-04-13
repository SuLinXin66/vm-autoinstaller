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

# SSH 密钥认证 + 允许控制台密码登录（用于调试）
ssh_pwauth: false

timezone: Asia/Shanghai

# Redirect all cloud-init output to both log file AND serial console
# so `virsh console` can show real-time progress
output:
  all: '| tee -a /var/log/cloud-init-output.log /dev/console'

# Enable serial console output in GRUB for future boots
bootcmd:
  - [sh, -c, 'test -f /etc/default/grub && grep -q "console=ttyS0" /etc/default/grub || (sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty1 console=ttyS0,115200 /" /etc/default/grub && update-grub)']
  - [sh, -c, 'mkdir -p /etc/needrestart/conf.d && echo "\$nrconf{restart} = \"a\";" > /etc/needrestart/conf.d/99-auto.conf']
  - [sh, -c, 'echo "DEBIAN_FRONTEND=noninteractive" >> /etc/environment && echo "NEEDRESTART_MODE=a" >> /etc/environment']

apt:
  conf: |
    Dpkg::Options {
      "--force-confdef";
      "--force-confold";
    };
    APT::Get::Assume-Yes "true";
    DPkg::Pre-Invoke {"export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a";};

package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - apt-transport-https
  - software-properties-common
  - ${GUEST_AGENT_PKG}

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
      apt-get update -q
      apt-get install -y -q \
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
  - |
    if [ "${GUEST_AGENT_SVC}" = "hv-kvp-daemon" ]; then
      apt-get install -y -q linux-cloud-tools-$(uname -r) || true
      udevadm trigger --subsystem-match=misc
    fi
  - systemctl enable --now ${GUEST_AGENT_SVC} || true
  - export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a && bash /opt/setup-docker.sh
  - echo "CLOUDINIT_SETUP_COMPLETE" > /var/log/cloud-init-done.log

final_message: "Cloud-init completed. System uptime: $UPTIME"
