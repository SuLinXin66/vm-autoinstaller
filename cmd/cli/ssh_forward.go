package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/gookit/color"

	"github.com/SuLinXin66/vm-autoinstaller/internal/share"
)

const sshForwardTag = "ssh-forward"

// ensureSSHForward mounts host ~/.ssh into VM ~/.ssh-host (read-only),
// installs common SSH proxy tools, symlinks key files, and adds
// Include ~/.ssh-host/config to the VM's SSH config.
// Called after setup/restart alongside ensureProxy/ensureMirror.
func ensureSSHForward() {
	cfg, err := loadConfig()
	if err != nil {
		return
	}
	if cfgVal(cfg, "SSH_FORWARD") != "1" {
		return
	}
	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		return
	}

	vmUser := cfgVal(cfg, "VM_USER")
	mountPoint := "/home/" + vmUser + "/.ssh-host"

	hostSSH := filepath.Join(homeDir(), ".ssh")
	if _, err := os.Stat(hostSSH); os.IsNotExist(err) {
		color.Yellow.Println("⚠ 宿主机 ~/.ssh 不存在，跳过 SSH 映射")
		return
	}

	s := &share.Share{
		Tag:        sshForwardTag,
		HostPath:   hostSSH,
		MountPoint: mountPoint,
		ReadOnly:   true,
		Enabled:    true,
	}

	// Already mounted — just ensure symlinks/tools are in place
	if isMounted(cfg, mountPoint) {
		applySSHForwardInVM(cfg, mountPoint)
		color.Green.Println("✓ SSH 映射已生效")
		return
	}

	// Attach the shared-folder device (9p on KVM, vboxsf on VBox).
	// Ignore "already exists" — the device was persisted on a previous run.
	if err := platformAttachShare(cfg, vmName, s, true); err != nil {
		if !strings.Contains(err.Error(), "already exists") {
			color.Yellow.Printf("⚠ SSH 共享设备附加失败: %v\n", err)
			return
		}
	}

	// Write fstab entry so it persists across reboots
	if err := ensureFstabEntry(cfg, s); err != nil {
		color.Yellow.Printf("⚠ SSH fstab 写入失败: %v\n", err)
		return
	}

	// Try to mount
	mountCmd := fmt.Sprintf(
		"sudo modprobe 9p 9pnet 9pnet_virtio vboxsf 2>/dev/null; sudo mkdir -p %s && sudo mount %s",
		mountPoint, mountPoint,
	)
	if _, err := sshExec(cfg, mountCmd); err != nil {
		// KVM 9p devices cannot be hot-plugged; a restart is required.
		if runtime.GOOS != "windows" {
			fmt.Println("SSH 共享设备需要重启 VM 生效（KVM 9p 不支持热插拔）...")
			if err := restartVM(); err != nil {
				color.Yellow.Printf("⚠ VM 重启失败: %v\n", err)
				return
			}
			// Re-mount user shares that were active before the restart
			remountShares()
			// Retry SSH mount after restart
			if _, err := sshExec(cfg, mountCmd); err != nil {
				color.Yellow.Printf("⚠ SSH 挂载失败: %v\n", err)
				return
			}
		} else {
			color.Yellow.Printf("⚠ SSH 挂载失败: %v\n", err)
			return
		}
	}

	applySSHForwardInVM(cfg, mountPoint)
	color.Green.Println("✓ SSH 映射已生效（密钥 + 配置 + Agent Forwarding）")
}

// applySSHForwardInVM installs proxy tools, symlinks host keys, and
// adds Include ~/.ssh-host/config to the VM's SSH config.
func applySSHForwardInVM(cfg map[string]string, mountPoint string) {
	// Install common SSH proxy tools so host ProxyCommand directives work
	installCmd := "dpkg -s netcat-openbsd &>/dev/null || " +
		"sudo apt-get install -y -qq netcat-openbsd connect-proxy socat 2>/dev/null || true"
	_, _ = sshExec(cfg, installCmd)

	// Symlink all key/config files from .ssh-host into .ssh
	// (skip authorized_keys, known_hosts*, config, and directories)
	script := fmt.Sprintf(`
if mountpoint -q %[1]s 2>/dev/null; then
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  for f in %[1]s/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      authorized_keys|known_hosts|known_hosts.old|config) continue ;;
    esac
    ln -sf "$f" "$HOME/.ssh/$base"
  done
  if [ -f %[1]s/config ] && ! grep -qF '/.ssh-host/config' ~/.ssh/config 2>/dev/null; then
    { echo 'Include ~/.ssh-host/config'; echo; cat ~/.ssh/config 2>/dev/null; } > ~/.ssh/config.new
    mv ~/.ssh/config.new ~/.ssh/config
  fi
  chmod 600 ~/.ssh/config 2>/dev/null || true
fi
`, mountPoint)
	_, _ = sshExec(cfg, script)
}

func homeDir() string {
	if runtime.GOOS == "windows" {
		return os.Getenv("USERPROFILE")
	}
	h, _ := os.UserHomeDir()
	return h
}
