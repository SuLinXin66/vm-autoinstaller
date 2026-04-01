package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/gookit/color"
	gotable "github.com/jedib0t/go-pretty/v6/table"
	"github.com/spf13/cobra"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/runner"
	"github.com/SuLinXin66/vm-autoinstaller/internal/share"
	"github.com/SuLinXin66/vm-autoinstaller/internal/tui"
)

// ---------------------------------------------------------------------------
// CLI commands
// ---------------------------------------------------------------------------

func newShareCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "share",
		Short: "管理宿主机与 VM 的共享目录",
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareList()
		},
	}

	addCmd := newShareAddCmd()
	rmCmd := &cobra.Command{
		Use:   "rm <name>",
		Short: "移除共享目录",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareRemove(args[0])
		},
	}
	lsCmd := &cobra.Command{
		Use:   "ls",
		Short: "列出所有共享目录",
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareList()
		},
	}
	enableCmd := &cobra.Command{
		Use:   "enable <name>",
		Short: "启用共享目录",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareSetEnabled(args[0], true)
		},
	}
	disableCmd := &cobra.Command{
		Use:   "disable <name>",
		Short: "禁用共享目录",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareSetEnabled(args[0], false)
		},
	}
	toggleCmd := &cobra.Command{
		Use:   "toggle",
		Short: "交互式切换共享目录启用状态",
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareToggle()
		},
	}

	cmd.AddCommand(addCmd, rmCmd, lsCmd, enableCmd, disableCmd, toggleCmd)
	return cmd
}

func newShareAddCmd() *cobra.Command {
	var name, mount, note string
	cmd := &cobra.Command{
		Use:   "add <host_path>",
		Short: "添加共享目录",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return shareAdd(args[0], name, mount, note)
		},
	}
	cmd.Flags().StringVar(&name, "name", "", "显示名（支持中文，默认: 目录 basename）")
	cmd.Flags().StringVar(&mount, "mount", "", "VM 挂载点（默认: /mnt/shares/<tag>）")
	cmd.Flags().StringVar(&note, "note", "", "备注")
	return cmd
}

// ---------------------------------------------------------------------------
// share add
// ---------------------------------------------------------------------------

func resolveVMMountPoint(cfg map[string]string, mountPoint string) string {
	if mountPoint == "" {
		return ""
	}
	vmUser := cfgVal(cfg, "VM_USER", "wpsweb")
	vmHome := "/home/" + vmUser
	if strings.HasPrefix(mountPoint, "~/") {
		return vmHome + mountPoint[1:]
	}
	if mountPoint == "~" {
		return vmHome
	}
	hostHome, _ := os.UserHomeDir()
	if hostHome != "" && strings.HasPrefix(mountPoint, hostHome+"/") {
		rel := mountPoint[len(hostHome):]
		color.Yellow.Printf("⚠ 检测到挂载点 %s 使用了宿主机家目录，已自动转换为 VM 路径: %s%s\n", mountPoint, vmHome, rel)
		return vmHome + rel
	}
	return mountPoint
}

func shareAdd(hostPath, name, mountPoint, note string) error {
	hostPath, err := filepath.Abs(hostPath)
	if err != nil {
		return fmt.Errorf("解析路径失败: %w", err)
	}
	if fi, err := os.Stat(hostPath); err != nil || !fi.IsDir() {
		return fmt.Errorf("宿主机目录不存在或不是目录: %s", hostPath)
	}

	if name == "" {
		name = share.DefaultName(hostPath)
	}

	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
	}

	mountPoint = resolveVMMountPoint(cfg, mountPoint)

	shares, err := share.Load()
	if err != nil {
		return err
	}

	if _, s := share.FindByName(shares, name); s != nil {
		return fmt.Errorf("名称 [%s] 已存在 (宿主机: %s → VM: %s)", name, s.HostPath, s.MountPoint)
	}

	tag := share.GenerateTag(hostPath, func() string {
		if mountPoint != "" {
			return mountPoint
		}
		return share.DefaultMountPoint(share.GenerateTag(hostPath, ""))
	}())

	if mountPoint == "" {
		mountPoint = share.DefaultMountPoint(tag)
	}

	tag = share.GenerateTag(hostPath, mountPoint)

	if _, s := share.FindByMapping(shares, hostPath, mountPoint); s != nil {
		return fmt.Errorf("映射已存在: [%s] %s → %s", s.Name, s.HostPath, s.MountPoint)
	}
	if _, s := share.FindByTag(shares, tag); s != nil {
		return fmt.Errorf("Tag 冲突（路径+挂载点哈希相同），已存在: [%s]", s.Name)
	}

	s := share.Share{
		Name:       name,
		Tag:        tag,
		HostPath:   hostPath,
		MountPoint: mountPoint,
		Enabled:    true,
		Note:       note,
		AddedAt:    time.Now(),
	}
	vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
	running := isVMRunning(cfg, vmName)

	if err := platformAttachShare(cfg, vmName, &s, running); err != nil {
		return fmt.Errorf("添加共享设备失败: %w", err)
	}

	rollback := func() {
		_ = platformDetachShare(cfg, vmName, &s, running)
	}

	mountOk := false

	if running {
		if runtime.GOOS == "windows" {
			if err := vboxMountShare(cfg, &s); err != nil {
				rollback()
				return fmt.Errorf("挂载失败: %w", err)
			}
			mountOk = true
			color.Green.Println("✓ 共享目录已添加并挂载")
		} else {
			fmt.Println("9p 设备已写入 VM 配置，需要重启 VM 才能生效。")
			if promptYN("是否立即重启 VM？", true) {
				if err := restartVM(); err != nil {
					return fmt.Errorf("重启 VM 失败: %w", err)
				}
				remountShares()
				if err := ensureFstabEntry(cfg, &s); err != nil {
					color.Yellow.Printf("⚠ fstab 写入失败: %v\n", err)
				}
				if err := sshMount(cfg, s.MountPoint); err != nil {
					color.Yellow.Printf("⚠ 挂载失败: %v\n", err)
				} else {
					mountOk = true
					color.Green.Println("✓ 共享目录已添加、重启并挂载成功")
				}
			} else {
				fmt.Println("共享目录将在下次启动 VM 时生效。")
			}
		}
	} else {
		fmt.Println("VM 未运行，已添加到配置。启动后自动挂载。")
	}

	shares = append(shares, s)
	if err := share.Save(shares); err != nil {
		return fmt.Errorf("保存配置失败: %w", err)
	}

	_ = mountOk
	return nil
}

// ---------------------------------------------------------------------------
// share rm
// ---------------------------------------------------------------------------

func shareRemove(name string) error {
	shares, err := share.Load()
	if err != nil {
		return err
	}
	idx, s := share.FindByName(shares, name)
	if s == nil {
		return fmt.Errorf("未找到共享目录: %s", name)
	}

	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
	}
	vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
	running := isVMRunning(cfg, vmName)

	if running {
		_, _ = sshExec(cfg, fmt.Sprintf("sudo umount %s 2>/dev/null", s.MountPoint))
		_ = removeFstabEntry(cfg, s.Tag)
	}

	if err := platformDetachShare(cfg, vmName, s, running); err != nil {
		color.Yellow.Printf("⚠ 移除设备失败: %v\n", err)
	}

	shares = append(shares[:idx], shares[idx+1:]...)
	if err := share.Save(shares); err != nil {
		return fmt.Errorf("保存配置失败: %w", err)
	}

	color.Green.Printf("✓ 共享目录 [%s] 已移除\n", name)
	return nil
}

// ---------------------------------------------------------------------------
// share ls
// ---------------------------------------------------------------------------

func shareList() error {
	shares, err := share.Load()
	if err != nil {
		return err
	}
	if len(shares) == 0 {
		fmt.Printf("暂无共享目录。使用 %s share add <path> 添加。\n", buildinfo.AppName)
		return nil
	}

	cfg, _ := loadConfig()
	vmName := ""
	running := false
	if cfg != nil {
		vmName = cfgVal(cfg, "VM_NAME", "ubuntu-server")
		running = isVMRunning(cfg, vmName)
	}

	tw := newTable("名称", "宿主机路径", "VM 挂载点", "状态", "备注")
	for _, s := range shares {
		status := shareStatus(cfg, &s, running)
		tw.AppendRow(gotable.Row{s.Name, s.HostPath, s.MountPoint, status, s.Note})
	}
	fmt.Println(tw.Render())
	return nil
}

func shareStatus(cfg map[string]string, s *share.Share, running bool) string {
	if !s.Enabled {
		return color.Gray.Sprint("⊘ 已禁用")
	}
	if !running {
		return color.Yellow.Sprint("⏸ 待启动")
	}
	if cfg != nil && isMounted(cfg, s.MountPoint) {
		return color.Green.Sprint("✓ 已生效")
	}
	return color.LightRed.Sprint("✗ 未生效")
}

// ---------------------------------------------------------------------------
// share enable / disable
// ---------------------------------------------------------------------------

func shareSetEnabled(name string, enabled bool) error {
	shares, err := share.Load()
	if err != nil {
		return err
	}
	_, s := share.FindByName(shares, name)
	if s == nil {
		return fmt.Errorf("未找到共享目录: %s", name)
	}
	if s.Enabled == enabled {
		if enabled {
			fmt.Printf("[%s] 已经是启用状态\n", name)
		} else {
			fmt.Printf("[%s] 已经是禁用状态\n", name)
		}
		return nil
	}

	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
	}
	vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
	running := isVMRunning(cfg, vmName)

	s.Enabled = enabled

	if enabled {
		if err := platformAttachShare(cfg, vmName, s, running); err != nil {
			color.Yellow.Printf("⚠ 挂载设备失败: %v\n", err)
		}
		if running {
			if runtime.GOOS == "windows" {
				if err := vboxMountShare(cfg, s); err != nil {
					color.Yellow.Printf("⚠ 挂载失败: %v\n", err)
				}
			} else {
				fmt.Println("9p 设备已写入 VM 配置，需要重启 VM 才能生效。")
				if promptYN("是否立即重启 VM？", true) {
					if err := restartVM(); err != nil {
						return fmt.Errorf("重启失败: %w", err)
					}
					remountShares()
					_ = ensureFstabEntry(cfg, s)
					_ = sshMount(cfg, s.MountPoint)
				}
			}
		}
	} else {
		if running {
			_, _ = sshExec(cfg, fmt.Sprintf("sudo umount %s 2>/dev/null", s.MountPoint))
			_ = removeFstabEntry(cfg, s.Tag)
		}
		if err := platformDetachShare(cfg, vmName, s, running); err != nil {
			color.Yellow.Printf("⚠ 分离设备失败: %v\n", err)
		}
	}

	if err := share.Save(shares); err != nil {
		return fmt.Errorf("保存配置失败: %w", err)
	}

	if enabled {
		color.Green.Printf("✓ [%s] 已启用\n", name)
	} else {
		fmt.Printf("⊘ [%s] 已禁用\n", name)
	}
	return nil
}

// ---------------------------------------------------------------------------
// share toggle (bubbletea TUI)
// ---------------------------------------------------------------------------

func shareToggle() error {
	shares, err := share.Load()
	if err != nil {
		return err
	}
	if len(shares) == 0 {
		fmt.Printf("暂无共享目录。使用 %s share add <path> 添加。\n", buildinfo.AppName)
		return nil
	}

	items := make([]tui.ToggleItem, len(shares))
	for i, s := range shares {
		label := fmt.Sprintf("%-14s %s → %s", s.Name, s.HostPath, s.MountPoint)
		items[i] = tui.ToggleItem{Name: s.Name, Label: label, Checked: s.Enabled}
	}

	result, err := tui.RunToggle(items)
	if err != nil {
		return err
	}
	if result.Cancelled {
		fmt.Println("已取消，未做任何变更。")
		return nil
	}

	changed := 0
	for i, item := range result.Items {
		if shares[i].Enabled != item.Checked {
			changed++
		}
	}
	if changed == 0 {
		fmt.Println("未做任何变更。")
		return nil
	}

	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
	}
	vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
	running := isVMRunning(cfg, vmName)
	needRestart := false

	for i, item := range result.Items {
		if shares[i].Enabled == item.Checked {
			continue
		}
		shares[i].Enabled = item.Checked
		if item.Checked {
			_ = platformAttachShare(cfg, vmName, &shares[i], running)
			if running && runtime.GOOS == "windows" {
				_ = vboxMountShare(cfg, &shares[i])
			}
			if running && runtime.GOOS != "windows" {
				needRestart = true
			}
		} else {
			if running {
				_, _ = sshExec(cfg, fmt.Sprintf("sudo umount %s 2>/dev/null", shares[i].MountPoint))
				_ = removeFstabEntry(cfg, shares[i].Tag)
			}
			_ = platformDetachShare(cfg, vmName, &shares[i], running)
		}
	}

	if err := share.Save(shares); err != nil {
		return fmt.Errorf("保存配置失败: %w", err)
	}

	color.Green.Printf("✓ 已更新 %d 项共享目录状态\n", changed)

	if needRestart {
		fmt.Println("部分变更需要重启 VM 才能生效（KVM 9p 设备变更）。")
		if promptYN("是否立即重启 VM？", true) {
			if err := restartVM(); err != nil {
				color.Yellow.Printf("⚠ 重启失败: %v\n", err)
			} else {
				remountShares()
			}
		}
	}

	return nil
}

// ---------------------------------------------------------------------------
// showShareSummary (called by showInfo)
// ---------------------------------------------------------------------------

func showShareSummary() {
	shares, err := share.Load()
	if err != nil || len(shares) == 0 {
		return
	}

	cfg, _ := loadConfig()
	vmName := ""
	running := false
	if cfg != nil {
		vmName = cfgVal(cfg, "VM_NAME", "ubuntu-server")
		running = isVMRunning(cfg, vmName)
	}

	fmt.Println()
	color.Bold.Println("共享目录:")
	tw := newTable("名称", "宿主机路径", "VM 挂载点", "状态", "备注")
	for _, s := range shares {
		status := shareStatus(cfg, &s, running)
		tw.AppendRow(gotable.Row{s.Name, s.HostPath, s.MountPoint, status, s.Note})
	}
	fmt.Println(tw.Render())
}

// ---------------------------------------------------------------------------
// remountShares (called after setup/start)
// ---------------------------------------------------------------------------

func remountShares() {
	shares, err := share.Load()
	if err != nil || len(shares) == 0 {
		return
	}

	cfg, err := loadConfig()
	if err != nil {
		return
	}
	vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
	if !isVMRunning(cfg, vmName) {
		return
	}

	mounted, failed := 0, 0
	for i := range shares {
		s := &shares[i]
		if !s.Enabled {
			continue
		}
		if isMounted(cfg, s.MountPoint) {
			mounted++
			continue
		}
		if runtime.GOOS == "windows" {
			_ = platformAttachShare(cfg, vmName, s, true)
		}
		if err := ensureFstabEntry(cfg, s); err != nil {
			color.Yellow.Printf("⚠ [%s] fstab 写入失败: %v\n", s.Name, err)
			failed++
			continue
		}
		if err := sshMount(cfg, s.MountPoint); err != nil {
			color.Yellow.Printf("⚠ [%s] 挂载失败: %v\n", s.Name, err)
			failed++
		} else {
			mounted++
		}
	}
	if mounted > 0 || failed > 0 {
		fmt.Printf("共享目录: %s 已挂载", color.Green.Sprintf("%d", mounted))
		if failed > 0 {
			fmt.Printf(", %s 失败", color.LightRed.Sprintf("%d", failed))
		}
		fmt.Println()
	}
}

// ---------------------------------------------------------------------------
// SSH helpers
// ---------------------------------------------------------------------------

func sshExec(cfg map[string]string, command string) (string, error) {
	user := cfgVal(cfg, "VM_USER", "wpsweb")
	dataDir := cfgVal(cfg, "DATA_DIR", defaultDataDir())
	keyPath := filepath.Join(dataDir, "id_ed25519")

	var sshHost, sshPort string
	if runtime.GOOS == "windows" {
		sshHost, sshPort = "127.0.0.1", "2222"
	} else {
		vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
		ip := getVirshIP(vmName)
		if ip == "" {
			return "", fmt.Errorf("无法获取 VM IP")
		}
		sshHost, sshPort = ip, "22"
	}

	args := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=" + knownHostsDevNull(),
		"-o", "LogLevel=ERROR",
		"-o", "ConnectTimeout=5",
		"-p", sshPort,
	}
	if _, err := os.Stat(keyPath); err == nil {
		if f, e := os.Open(keyPath); e == nil {
			f.Close()
			args = append(args, "-i", keyPath)
		} else if runtime.GOOS != "windows" {
			return "", fmt.Errorf("SSH 密钥 %s 无法读取（属于 root），请执行: sudo chown $USER %s", keyPath, keyPath)
		}
	} else {
		return "", fmt.Errorf("SSH 密钥不存在: %s", keyPath)
	}
	args = append(args, fmt.Sprintf("%s@%s", user, sshHost), command)

	cmd := exec.Command("ssh", args...)
	out, err := cmd.CombinedOutput()
	outStr := strings.TrimSpace(string(out))
	if err != nil && outStr != "" {
		return outStr, fmt.Errorf("%s", outStr)
	}
	return outStr, err
}

func isMounted(cfg map[string]string, mountPoint string) bool {
	_, err := sshExec(cfg, fmt.Sprintf("mountpoint -q %s 2>/dev/null", mountPoint))
	return err == nil
}

func sshMount(cfg map[string]string, mountPoint string) error {
	cmd := fmt.Sprintf(
		"sudo modprobe 9p 9pnet 9pnet_virtio 2>/dev/null; sudo mkdir -p %s && sudo mount %s",
		mountPoint, mountPoint,
	)
	_, err := sshExec(cfg, cmd)
	return err
}

// ---------------------------------------------------------------------------
// VM state helpers
// ---------------------------------------------------------------------------

func isVMRunning(cfg map[string]string, vmName string) bool {
	if runtime.GOOS == "windows" {
		out, err := exec.Command(findVBoxManage(), "showvminfo", vmName, "--machinereadable").CombinedOutput()
		if err != nil {
			return false
		}
		for _, line := range strings.Split(string(out), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "VMState=") {
				val := strings.TrimSpace(strings.Trim(strings.TrimPrefix(line, "VMState="), "\""))
				return val == "running"
			}
		}
		return false
	}
	out, err := runVirsh("dominfo", vmName)
	if err != nil {
		return false
	}
	info := parseVirshKV(out)
	return info["State"] == "running"
}

func restartVM() error {
	if err := runner.RunScript("stop"); err != nil {
		return err
	}
	return runner.RunScript("start")
}

// ---------------------------------------------------------------------------
// fstab management (via SSH)
// ---------------------------------------------------------------------------

func fstabMarker(tag string) string {
	return fmt.Sprintf("%s:share:%s", buildinfo.AppName, tag)
}

func ensureFstabEntry(cfg map[string]string, s *share.Share) error {
	marker := fstabMarker(s.Tag)
	out, _ := sshExec(cfg, fmt.Sprintf("grep -c '%s' /etc/fstab 2>/dev/null", marker))
	if strings.TrimSpace(out) != "0" && out != "" {
		return nil
	}

	var fstabLine string
	if runtime.GOOS == "windows" {
		fstabLine = fmt.Sprintf("%s %s vboxsf uid=1000,gid=1000,_netdev,nofail 0 0", s.Tag, s.MountPoint)
	} else {
		fstabLine = fmt.Sprintf("%s %s 9p trans=virtio,version=9p2000.L,rw,_netdev,nofail 0 0", s.Tag, s.MountPoint)
	}

	cmd := fmt.Sprintf("printf '\\n# %s\\n%s\\n' | sudo tee -a /etc/fstab > /dev/null", marker, fstabLine)
	_, err := sshExec(cfg, cmd)
	return err
}

func removeFstabEntry(cfg map[string]string, tag string) error {
	marker := fstabMarker(tag)
	cmd := fmt.Sprintf("sudo sed -i '/# %s/,+1d' /etc/fstab", marker)
	_, err := sshExec(cfg, cmd)
	return err
}

// ---------------------------------------------------------------------------
// Platform dispatch
// ---------------------------------------------------------------------------

func platformAttachShare(cfg map[string]string, vmName string, s *share.Share, running bool) error {
	if runtime.GOOS == "windows" {
		return vboxAttachShare(vmName, s, running)
	}
	return kvmAttachShare(vmName, s)
}

func platformDetachShare(cfg map[string]string, vmName string, s *share.Share, running bool) error {
	if runtime.GOOS == "windows" {
		return vboxDetachShare(vmName, s, running)
	}
	return kvmDetachShare(vmName, s)
}

// ---------------------------------------------------------------------------
// KVM (Linux) — 9p virtio passthrough
// ---------------------------------------------------------------------------

func generate9pXML(hostPath, tag string) string {
	return fmt.Sprintf(`<filesystem type='mount' accessmode='passthrough'>
  <driver type='path' wrpolicy='immediate'/>
  <source dir='%s'/>
  <target dir='%s'/>
</filesystem>`, hostPath, tag)
}

func ensureDACLabel(vmName string) error {
	uid := os.Getuid()
	gid := os.Getgid()
	label := fmt.Sprintf("+%d:+%d", uid, gid)

	xmlOut, err := runVirsh("dumpxml", "--inactive", vmName)
	if err != nil {
		return fmt.Errorf("获取 VM 配置失败: %w", err)
	}

	if strings.Contains(xmlOut, "model='dac'") && strings.Contains(xmlOut, label) {
		return nil
	}

	re := regexp.MustCompile(`(?s)<seclabel[^>]*model='dac'[^>]*>.*?</seclabel>\s*`)
	xmlOut = re.ReplaceAllString(xmlOut, "")

	seclabel := fmt.Sprintf("  <seclabel type='static' model='dac' relabel='yes'>\n    <label>%s</label>\n  </seclabel>\n</domain>", label)
	xmlOut = strings.Replace(xmlOut, "</domain>", seclabel, 1)

	f, err := os.CreateTemp("", "domain-*.xml")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(xmlOut); err != nil {
		f.Close()
		return err
	}
	f.Close()

	fmt.Printf("配置 QEMU 以当前用户 (UID %d) 运行...\n", uid)
	_, err = runVirsh("define", f.Name())
	if err != nil {
		return fmt.Errorf("更新 VM 配置失败: %w", err)
	}
	color.Green.Printf("✓ QEMU 将以 UID %d 运行，共享目录权限完全匹配\n", uid)
	return nil
}

func kvmAttachShare(vmName string, s *share.Share) error {
	if err := ensureDACLabel(vmName); err != nil {
		color.Yellow.Printf("⚠ 设置 DAC 标签失败: %v\n", err)
		color.Yellow.Println("  VM 内可能无法写入共享目录")
	}

	xml := generate9pXML(s.HostPath, s.Tag)

	f, err := os.CreateTemp("", "share-*.xml")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(xml); err != nil {
		f.Close()
		return err
	}
	f.Close()

	_, err = runVirsh("attach-device", vmName, f.Name(), "--config")
	return err
}

func kvmDetachShare(vmName string, s *share.Share) error {
	xml := generate9pXML(s.HostPath, s.Tag)

	f, err := os.CreateTemp("", "share-*.xml")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(xml); err != nil {
		f.Close()
		return err
	}
	f.Close()

	_, err = runVirsh("detach-device", vmName, f.Name(), "--config")
	return err
}

// ---------------------------------------------------------------------------
// VirtualBox (Windows) — VBoxManage sharedfolder
// ---------------------------------------------------------------------------

var cachedVBoxManagePath string

func findVBoxManage() string {
	if cachedVBoxManagePath != "" {
		return cachedVBoxManagePath
	}
	if p, err := exec.LookPath("VBoxManage"); err == nil {
		cachedVBoxManagePath = p
		return p
	}
	if runtime.GOOS == "windows" {
		candidates := []string{
			filepath.Join(os.Getenv("ProgramFiles"), "Oracle", "VirtualBox", "VBoxManage.exe"),
			filepath.Join(os.Getenv("ProgramFiles(x86)"), "Oracle", "VirtualBox", "VBoxManage.exe"),
		}
		for _, c := range candidates {
			if _, err := os.Stat(c); err == nil {
				cachedVBoxManagePath = c
				return c
			}
		}
	}
	return "VBoxManage"
}

func runVBoxManage(args ...string) error {
	cmd := exec.Command(findVBoxManage(), args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		outStr := strings.TrimSpace(string(out))
		if outStr != "" {
			return fmt.Errorf("%s", outStr)
		}
		return err
	}
	return nil
}

func vboxAttachShare(vmName string, s *share.Share, running bool) error {
	errTransient := runVBoxManage("sharedfolder", "add", vmName,
		"--name", s.Tag, "--hostpath", s.HostPath, "--transient")
	errPersistent := runVBoxManage("sharedfolder", "add", vmName,
		"--name", s.Tag, "--hostpath", s.HostPath)

	if errTransient != nil && errPersistent != nil {
		if running {
			return errTransient
		}
		return errPersistent
	}
	return nil
}

func vboxDetachShare(vmName string, s *share.Share, running bool) error {
	errTransient := runVBoxManage("sharedfolder", "remove", vmName, "--name", s.Tag, "--transient")
	errPersistent := runVBoxManage("sharedfolder", "remove", vmName, "--name", s.Tag)
	if errTransient != nil && errPersistent != nil {
		if running {
			return errTransient
		}
		return errPersistent
	}
	return nil
}

func vboxMountShare(cfg map[string]string, s *share.Share) error {
	if err := ensureFstabEntry(cfg, s); err != nil {
		return err
	}
	cmd := fmt.Sprintf(
		"sudo modprobe vboxsf 2>/dev/null; sudo mkdir -p %s && sudo mount %s",
		s.MountPoint, s.MountPoint,
	)
	_, err := sshExec(cfg, cmd)
	return err
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func promptYN(msg string, defaultY bool) bool {
	suffix := "[y/N]"
	if defaultY {
		suffix = "[Y/n]"
	}
	fmt.Printf("%s %s ", msg, suffix)
	var answer string
	fmt.Scanln(&answer)
	answer = strings.TrimSpace(strings.ToLower(answer))
	if answer == "" {
		return defaultY
	}
	return answer == "y" || answer == "yes"
}
