package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/gookit/color"
	gotable "github.com/jedib0t/go-pretty/v6/table"
	"github.com/spf13/cobra"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/config"
	"github.com/SuLinXin66/vm-autoinstaller/internal/hostinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/meta"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
	"github.com/SuLinXin66/vm-autoinstaller/internal/pathmgr"
	"github.com/SuLinXin66/vm-autoinstaller/internal/runner"
)

func main() {
	root := newRootCmd()
	if err := root.Execute(); err != nil {
		// Script errors (ExitError) are already printed to stderr by the script itself.
		// Only print Go-level errors (unknown command, config missing, etc.).
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		}
		os.Exit(1)
	}
}

func newRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:     buildinfo.AppName,
		Short:   "KVM/VirtualBox Ubuntu VM 管理工具",
		Version: buildinfo.Version,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSSH()
		},
		SilenceUsage:  true,
		SilenceErrors: true,
	}

	root.CompletionOptions = cobra.CompletionOptions{
		DisableDefaultCmd: true,
	}

	root.AddCommand(
		newSetupCmd(),
		newStopCmd(),
		newRestartCmd(),
		newStatusCmd(),
		newDestroyCmd(),
		newProvisionCmd(),
		newSSHCmd(),
		newChromeCmd(),
		newExecCmd(),
		newCpCmd(),
		newConfigCmd(),
		newInfoCmd(),
		newShareCmd(),
		newSyncCmd(),
		newUpgradeCmd(),
		newUninstallCmd(),
		newGenCompletionCmd(root),
	)

	return root
}

// --- _gen-completion (internal, called by installer) ---

func newGenCompletionCmd(root *cobra.Command) *cobra.Command {
	return &cobra.Command{
		Use:    "_gen-completion",
		Hidden: true,
		Args:   cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			switch args[0] {
			case "bash":
				return root.GenBashCompletionV2(os.Stdout, true)
			case "zsh":
				return root.GenZshCompletion(os.Stdout)
			case "fish":
				return root.GenFishCompletion(os.Stdout, true)
			case "powershell":
				return genPowerShellCompletion()
			}
			return fmt.Errorf("unknown shell: %s", args[0])
		},
	}
}

func genPowerShellCompletion() error {
	name := buildinfo.AppName
	varName := strings.ReplaceAll(strings.ReplaceAll(name, "-", "_"), ":", "_")

	// Cobra's generated PS completion script is incompatible with Windows
	// PowerShell 5.1. Generate a minimal script that calls __complete directly.
	// %[3]s is the backtick character (cannot appear in Go raw strings).
	script := fmt.Sprintf(`[scriptblock]$__%[2]sCompleterBlock = {
    param($wordToComplete, $commandAst, $cursorPosition)
    $cmd = $commandAst.ToString()
    if ($cmd.Length -gt $cursorPosition) { $cmd = $cmd.Substring(0, $cursorPosition) }
    $null = $cmd -match '^(\S+)\s*(.*)?$'
    $prog = $Matches[1]; $argPart = $Matches[2]
    $req = "$prog __complete"
    if ($argPart) { $req += " $argPart" }
    if ($wordToComplete -eq '') {
        if ($PSVersionTable.PSVersion -ge [version]'7.3.0' -and $PSNativeCommandArgumentPassing -ne 'Legacy') {
            $req += ' ""'
        } else {
            $req += ' %[3]s"%[3]s"'
        }
    }
    [array]$out = (Invoke-Expression $req) 2>$null
    if (-not $out -or $out.Length -lt 2) { return }
    for ($i = 0; $i -lt $out.Length - 1; $i++) {
        $line = $out[$i]; if (-not $line) { continue }
        $sep = $line.IndexOf([char]9)
        if ($sep -ge 0) { $t = $line.Substring(0,$sep); $d = $line.Substring($sep+1) }
        else            { $t = $line; $d = ' ' }
        if (-not $d) { $d = ' ' }
        if ($t) { [System.Management.Automation.CompletionResult]::new($t, $t, 'ParameterValue', $d) }
    }
}
Register-ArgumentCompleter -Native -CommandName '%[1]s' -ScriptBlock $__%[2]sCompleterBlock
Register-ArgumentCompleter -Native -CommandName '%[1]s.exe' -ScriptBlock $__%[2]sCompleterBlock
`, name, varName, "`")

	_, err := os.Stdout.WriteString(script)
	return err
}

// --- SSH (root + explicit) ---

func runSSH() error {
	if _, err := ensureVMRunning(); err != nil {
		return err
	}
	return runner.RunScript("ssh")
}

func newSSHCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ssh",
		Short: "SSH 连入 VM",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSSH()
		},
	}
}

// --- setup ---

func newSetupCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "setup",
		Short: "智能入口：VM 不存在时安装，已存在时启动",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := runner.RunScript("setup", args...); err != nil {
				return err
			}
			saveConfigSnapshot()
			remountShares()
			return nil
		},
	}
}

// --- stop ---

func newStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "停止 VM",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runner.RunScript("stop", args...)
		},
	}
}

// --- restart ---

func newRestartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "restart",
		Short: "重启 VM（stop + start）",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := restartVM(); err != nil {
				return err
			}
			remountShares()
			return nil
		},
	}
}

// --- status ---

func newStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "查看 VM 运行状态",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runner.RunScript("status", args...)
		},
	}
}

// --- destroy ---

func newDestroyCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "destroy",
		Short: "销毁 VM、清理磁盘和 SSH 密钥",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := runner.RunScript("destroy", args...); err != nil {
				return err
			}
			// VM destroyed → current config becomes the new baseline
			saveConfigSnapshot()
			return nil
		},
	}
}

// --- provision ---

func newProvisionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "provision",
		Short: "推送并执行 extensions/ 中的扩展脚本",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := runner.RunScript("provision", args...); err != nil {
				return err
			}
			saveConfigSnapshot()
			return nil
		},
	}
}

// --- chrome ---

func newChromeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "chrome",
		Short: "Chrome 浏览器转发到宿主机桌面",
		RunE: func(cmd *cobra.Command, args []string) error {
			if _, err := ensureVMRunning(); err != nil {
				return err
			}
			return runner.RunScript("chrome", args...)
		},
	}
}

// --- exec ---

func newExecCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "exec -- <command>",
		Short: "在 VM 内执行命令（非交互）",
		Long:  "在 VM 内通过 SSH 执行指定命令，不进入交互 Shell",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := ensureVMRunning()
			if err != nil {
				return err
			}
			user := cfgVal(cfg, "VM_USER")
			dataDir := cfgVal(cfg, "DATA_DIR")
			keyPath := filepath.Join(dataDir, "id_ed25519")

			sshHost, sshPort := resolveSSHEndpoint(cfg)

			sshArgs := []string{
				"-o", "StrictHostKeyChecking=no",
				"-o", "UserKnownHostsFile=" + knownHostsDevNull(),
				"-o", "LogLevel=ERROR",
				"-p", sshPort,
			}
			if _, err := os.Stat(keyPath); err == nil {
				if f, e := os.Open(keyPath); e == nil {
					f.Close()
					sshArgs = append(sshArgs, "-i", keyPath)
				} else {
					return fmt.Errorf("SSH 密钥 %s 无法读取（属于 root），请执行: sudo chown $USER %s", keyPath, keyPath)
				}
			}
			sshArgs = append(sshArgs, fmt.Sprintf("%s@%s", user, sshHost))
			sshArgs = append(sshArgs, args...)

			c := exec.Command("ssh", sshArgs...)
			c.Stdin = os.Stdin
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			return c.Run()
		},
	}
	return cmd
}

// --- cp ---

func newCpCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cp <src> <dst>",
		Short: "宿主机与 VM 间拷贝文件",
		Long: fmt.Sprintf(`使用 scp 在宿主机与 VM 间传输文件。

用法示例:
  %s cp local.txt vm:/tmp/            # 上传到 VM
  %s cp vm:/tmp/remote.txt ./         # 从 VM 下载
  
vm: 前缀表示 VM 内路径。`, buildinfo.AppName, buildinfo.AppName),
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := ensureVMRunning()
			if err != nil {
				return err
			}
			user := cfgVal(cfg, "VM_USER")
			dataDir := cfgVal(cfg, "DATA_DIR")
			keyPath := filepath.Join(dataDir, "id_ed25519")
			sshHost, sshPort := resolveSSHEndpoint(cfg)

			scpArgs := []string{
				"-o", "StrictHostKeyChecking=no",
				"-o", "UserKnownHostsFile=" + knownHostsDevNull(),
				"-o", "LogLevel=ERROR",
				"-P", sshPort,
			}
			if _, err := os.Stat(keyPath); err == nil {
				if f, e := os.Open(keyPath); e == nil {
					f.Close()
					scpArgs = append(scpArgs, "-i", keyPath)
				} else {
					return fmt.Errorf("SSH 密钥 %s 无法读取（属于 root），请执行: sudo chown $USER %s", keyPath, keyPath)
				}
			}

			for _, a := range args {
				if strings.HasPrefix(a, "vm:") {
					remotePath := strings.TrimPrefix(a, "vm:")
					scpArgs = append(scpArgs, fmt.Sprintf("%s@%s:%s", user, sshHost, remotePath))
				} else {
					scpArgs = append(scpArgs, a)
				}
			}

			c := exec.Command("scp", scpArgs...)
			c.Stdin = os.Stdin
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			return c.Run()
		},
	}
}

// --- config ---

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "查看/修改配置",
		RunE: func(cmd *cobra.Command, args []string) error {
			return showConfig()
		},
	}

	setCmd := &cobra.Command{
		Use:   "set <key> <value>",
		Short: "修改配置项",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return setConfig(args[0], args[1])
		},
	}

	pendingCmd := &cobra.Command{
		Use:   "pending",
		Short: "列出已改未生效的配置项",
		RunE: func(cmd *cobra.Command, args []string) error {
			return showPending()
		},
	}

	editCmd := &cobra.Command{
		Use:   "edit",
		Short: "使用编辑器打开配置文件",
		RunE: func(cmd *cobra.Command, args []string) error {
			editor := os.Getenv("EDITOR")
			if editor == "" {
				editor = "vi"
				if runtime.GOOS == "windows" {
					editor = "notepad"
				}
			}
			c := exec.Command(editor, paths.ConfigEnvPath())
			c.Stdin = os.Stdin
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			return c.Run()
		},
	}

	cmd.AddCommand(setCmd, pendingCmd, editCmd)
	return cmd
}

func newTable(headers ...string) gotable.Writer {
	tw := gotable.NewWriter()
	tw.SetOutputMirror(nil)
	row := make(gotable.Row, len(headers))
	for i, h := range headers {
		row[i] = h
	}
	tw.AppendHeader(row)
	tw.SetStyle(gotable.StyleLight)
	tw.Style().Options.SeparateRows = false
	return tw
}

func showConfig() error {
	cfgPath := paths.ConfigEnvPath()
	env, err := config.ReadEnv(cfgPath)
	if err != nil {
		return fmt.Errorf("无法读取配置: %v", err)
	}

	pending := config.PendingChanges(cfgPath, paths.ConfigSnapshotPath())
	hasPending := len(pending) > 0

	tw := newTable("键", "当前值", "状态", "说明", "备注")

	allKeys := make(map[string]bool)
	for k := range config.KnownKeys {
		allKeys[k] = true
	}
	for k := range env {
		allKeys[k] = true
	}

	sorted := config.SortedKeys(allKeys)

	for _, key := range sorted {
		val := env[key]
		m, known := config.KnownKeys[key]
		desc := ""
		remark := ""
		status := color.Green.Sprint("✓ 已生效")

		if known {
			desc = m.Description
			if m.EffectLevel != config.LevelNone {
				remark = "修改后" + m.EffectLevel.String()
			}
			if val == "" {
				val = m.DefaultValue + " (默认)"
			}
		}

		if oldVal, isPending := pending[key]; isPending {
			status = color.LightRed.Sprint("⚠ 待生效")
			val = color.LightRed.Sprint(val)
			if oldVal != "" {
				remark = "生效值: " + oldVal
			} else {
				remark = "新增，尚未生效"
			}
			if known && m.EffectLevel != config.LevelNone {
				remark += " (" + m.EffectLevel.String() + ")"
			}
		}

		tw.AppendRow(gotable.Row{key, val, status, desc, remark})
	}

	fmt.Println(tw.Render())

	if hasPending {
		fmt.Println()
		fmt.Println(color.LightRed.Sprint("⚠ 有配置已修改但未生效，请执行以下命令使其生效:"))
		needRestart := false
		needRebuild := false
		for k := range pending {
			if m, ok := config.KnownKeys[k]; ok {
				switch m.EffectLevel {
				case config.LevelRestart:
					needRestart = true
				case config.LevelRebuild:
					needRebuild = true
				}
			}
		}
		if needRebuild {
			fmt.Printf("  %s destroy && %s setup   (重建 VM)\n", buildinfo.AppName, buildinfo.AppName)
		} else if needRestart {
			fmt.Printf("  %s stop && %s setup      (重启 VM)\n", buildinfo.AppName, buildinfo.AppName)
		}
	}

	return nil
}

func setConfig(key, value string) error {
	if err := config.ValidateValue(key, value); err != nil {
		return err
	}
	if err := validateResourceChange(key, value); err != nil {
		return err
	}

	if m, known := config.KnownKeys[key]; !known {
		fmt.Fprintf(os.Stderr, "⚠ 未知的配置键: %s（可能是拼写错误）\n", key)
		fmt.Print("是否继续写入? [y/N] ")
		var answer string
		fmt.Scanln(&answer)
		if !strings.EqualFold(answer, "y") && !strings.EqualFold(answer, "yes") {
			fmt.Println("已取消")
			return nil
		}
	} else if m.EffectLevel != config.LevelNone {
		fmt.Printf("⚠ 修改 %s %s才能生效。\n", key, m.EffectLevel)
		fmt.Print("是否继续? [Y/n] ")
		var answer string
		fmt.Scanln(&answer)
		if strings.EqualFold(answer, "n") || strings.EqualFold(answer, "no") {
			fmt.Println("已取消")
			return nil
		}
	}

	cfgPath := paths.ConfigEnvPath()
	if err := config.WriteValue(cfgPath, key, value); err != nil {
		return fmt.Errorf("写入失败: %v", err)
	}
	fmt.Printf("✓ %s=%s 已写入\n", key, value)
	if m, ok := config.KnownKeys[key]; ok && m.EffectLevel != config.LevelNone {
		fmt.Printf("  提示: %s后才会生效。\n", m.EffectLevel)
	}
	return nil
}

func showPending() error {
	cfgPath := paths.ConfigEnvPath()
	pending := config.PendingChanges(cfgPath, paths.ConfigSnapshotPath())
	if pending == nil {
		fmt.Println("尚无配置快照（首次 setup 后将自动建立基准）。")
		return nil
	}
	if len(pending) == 0 {
		fmt.Println(color.Green.Sprint("✓ 所有配置均已生效，无待生效变更。"))
		return nil
	}

	current, _ := config.ReadEnv(cfgPath)
	tw := newTable("键", "当前值(未生效)", "生效中的值", "所需操作")
	for _, k := range config.SortedKeys(pending) {
		cur := current[k]
		old := pending[k]
		action := ""
		if m, ok := config.KnownKeys[k]; ok && m.EffectLevel != config.LevelNone {
			action = m.EffectLevel.String()
		}
		tw.AppendRow(gotable.Row{k, color.LightRed.Sprint(cur), old, action})
	}
	fmt.Println(tw.Render())
	return nil
}

// --- info ---

func newInfoCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "info",
		Short: "查看应用信息、VM 状态、版本等",
		RunE: func(cmd *cobra.Command, args []string) error {
			return showInfo()
		},
	}
}

func showInfo() error {
	tw := newTable("项目", "值")
	tw.AppendRow(gotable.Row{"应用名称", buildinfo.AppName})
	tw.AppendRow(gotable.Row{"CLI 版本", buildinfo.Version})
	tw.AppendRow(gotable.Row{"仓库地址", buildinfo.RepoURL})
	tw.AppendRow(gotable.Row{"分支", buildinfo.Branch})
	tw.AppendRow(gotable.Row{"数据目录", paths.DataRoot()})
	tw.AppendRow(gotable.Row{"脚本目录", paths.ScriptDir()})

	metaPath := paths.MetaPath()
	if m, err := meta.Load(metaPath); err == nil {
		tw.AppendRow(gotable.Row{"Bundle 版本", m.BundleVersion})
	}

	cfgPath := paths.ConfigEnvPath()
	cfg, cfgErr := config.ReadEnv(cfgPath)
	if cfgErr == nil {
		vmName := cfgVal(cfg, "VM_NAME")
		dataDir := cfgVal(cfg, "DATA_DIR")
		tw.AppendRow(gotable.Row{"VM 名称", vmName})
		tw.AppendRow(gotable.Row{"VM 数据目录", dataDir})

		if runtime.GOOS == "windows" {
			addVBoxInfo(tw, vmName)
		} else {
			addKVMInfo(tw, vmName)
		}
	}

	fmt.Println(tw.Render())

	if cfgErr == nil {
		showShareSummary()
	}
	return nil
}

// --- VM resource helpers (KVM/libvirt) ---

func runVirsh(args ...string) (string, error) {
	allArgs := append([]string{"-c", "qemu:///system"}, args...)

	cmd := exec.Command("virsh", allArgs...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err == nil {
		return string(out), nil
	}

	// sudo resets env, so pass LC_ALL=C via env(1)
	sudoArgs := append([]string{"-n", "env", "LC_ALL=C", "virsh"}, allArgs...)
	out, err = exec.Command("sudo", sudoArgs...).CombinedOutput()
	if err == nil {
		return string(out), nil
	}
	msg := strings.TrimSpace(string(out))
	if msg != "" {
		return "", fmt.Errorf("%s", msg)
	}
	return "", err
}

func parseKiB(s string) int64 {
	s = strings.TrimSpace(s)
	s = strings.TrimSuffix(s, " KiB")
	s = strings.TrimSuffix(s, " kB")
	v, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return v
}

func formatMem(kib int64) string {
	mb := kib / 1024
	if mb >= 1024 {
		return fmt.Sprintf("%.1f GB", float64(mb)/1024)
	}
	return fmt.Sprintf("%d MB", mb)
}

func addKVMInfo(tw gotable.Writer, vmName string) {
	out, err := runVirsh("dominfo", vmName)
	if err != nil {
		tw.AppendRow(gotable.Row{"VM 状态", color.LightRed.Sprint("未创建")})
		return
	}

	info := parseVirshKV(out)
	state := info["State"]

	switch state {
	case "running":
		tw.AppendRow(gotable.Row{"VM 状态", color.Green.Sprint("运行中")})
	case "shut off":
		tw.AppendRow(gotable.Row{"VM 状态", color.Yellow.Sprint("已关机")})
		return
	case "paused":
		tw.AppendRow(gotable.Row{"VM 状态", color.Yellow.Sprint("已暂停")})
		return
	case "":
		tw.AppendRow(gotable.Row{"VM 状态", color.LightRed.Sprint("未知")})
		return
	default:
		tw.AppendRow(gotable.Row{"VM 状态", state})
		return
	}

	if ip := getVirshIP(vmName); ip != "" {
		tw.AppendRow(gotable.Row{"VM IP", ip})
	}

	if cpus := info["CPU(s)"]; cpus != "" {
		tw.AppendRow(gotable.Row{"VM CPU", cpus + " 核"})
	}
	if cpuTime := info["CPU time"]; cpuTime != "" {
		tw.AppendRow(gotable.Row{"VM CPU 时间", cpuTime})
	}

	maxMem := parseKiB(info["Max memory"])
	usedMem := parseKiB(info["Used memory"])
	memStr := formatMem(usedMem)
	if maxMem > 0 && maxMem != usedMem {
		memStr += fmt.Sprintf(" / %s", formatMem(maxMem))
	}

	rss := getVirshRSS(vmName)
	if rss > 0 {
		memStr += fmt.Sprintf("  (宿主机 RSS: %s)", formatMem(rss))
	}
	tw.AppendRow(gotable.Row{"VM 内存", memStr})
}

func parseVirshKV(out string) map[string]string {
	m := make(map[string]string)
	for _, line := range strings.Split(out, "\n") {
		idx := strings.Index(line, ":")
		if idx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		m[key] = val
	}
	return m
}

func getVirshIP(vmName string) string {
	out, err := runVirsh("domifaddr", vmName)
	if err != nil {
		out, err = runVirsh("net-dhcp-leases", "default")
		if err != nil {
			return ""
		}
		for _, line := range strings.Split(out, "\n") {
			if strings.Contains(line, vmName) {
				for _, field := range strings.Fields(line) {
					if strings.Contains(field, ".") && strings.Contains(field, "/") {
						return strings.SplitN(field, "/", 2)[0]
					}
				}
			}
		}
		return ""
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		for _, f := range fields {
			if strings.Contains(f, ".") && strings.Contains(f, "/") {
				return strings.SplitN(f, "/", 2)[0]
			}
		}
	}
	return ""
}

func getVirshRSS(vmName string) int64 {
	out, err := runVirsh("dommemstat", vmName)
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "rss" {
			v, _ := strconv.ParseInt(fields[1], 10, 64)
			return v
		}
	}
	return 0
}

func addVBoxInfo(tw gotable.Writer, vmName string) {
	out, err := exec.Command(findVBoxManage(), "showvminfo", vmName, "--machinereadable").CombinedOutput()
	if err != nil {
		tw.AppendRow(gotable.Row{"VM 状态", color.LightRed.Sprint("未创建")})
		return
	}

	info := make(map[string]string)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			info[strings.TrimSpace(parts[0])] = strings.TrimSpace(strings.Trim(parts[1], "\""))
		}
	}

	switch info["VMState"] {
	case "running":
		tw.AppendRow(gotable.Row{"VM 状态", color.Green.Sprint("运行中")})
	case "poweroff":
		tw.AppendRow(gotable.Row{"VM 状态", color.Yellow.Sprint("已关机")})
		return
	default:
		tw.AppendRow(gotable.Row{"VM 状态", info["VMState"]})
		return
	}

	if cpus := info["cpus"]; cpus != "" {
		tw.AppendRow(gotable.Row{"VM CPU", cpus + " 核"})
	}
	if mem := info["memory"]; mem != "" {
		tw.AppendRow(gotable.Row{"VM 内存", mem + " MB"})
	}
}

// --- sync ---

func newSyncCmd() *cobra.Command {
	dryRun := false
	cmd := &cobra.Command{
		Use:   "sync",
		Short: "增量更新脚本资源（不覆盖用户配置）",
		Long:  "从 Release 下载最新脚本包并更新本地 repo 目录。不覆盖 config.env。",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSync(dryRun)
		},
	}
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "仅检查，不实际更新")
	return cmd
}

func runSync(dryRun bool) error {
	if buildinfo.RepoURL == "" {
		return fmt.Errorf("未配置 REPO_URL，无法检查更新")
	}

	repoURL := buildinfo.RepoURL
	// Convert SSH git URL to HTTPS API URL
	if strings.HasPrefix(repoURL, "git@github.com:") {
		repoURL = "https://github.com/" + strings.TrimSuffix(strings.TrimPrefix(repoURL, "git@github.com:"), ".git")
	}

	fmt.Printf("检查更新: %s (分支: %s)\n", repoURL, buildinfo.Branch)

	if dryRun {
		fmt.Println("[dry-run] 不实际执行更新。")
		fmt.Printf("下载地址: %s/archive/refs/heads/%s.tar.gz\n", repoURL, buildinfo.Branch)
		return nil
	}

	fmt.Println("sync 功能将从 GitHub Release 下载最新脚本包。")
	fmt.Println("当前版本: " + buildinfo.Version)
	fmt.Printf("请手动下载并重新运行 installer，或访问:\n")
	fmt.Printf("  %s/releases\n", repoURL)
	return nil
}

// --- upgrade ---

func newUpgradeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "upgrade",
		Short: "检查 CLI/installer 新版本",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runUpgradeCheck()
		},
	}
}

func runUpgradeCheck() error {
	if buildinfo.RepoURL == "" {
		return fmt.Errorf("未配置 REPO_URL，无法检查更新")
	}

	repoURL := buildinfo.RepoURL
	if strings.HasPrefix(repoURL, "git@github.com:") {
		repoURL = "https://github.com/" + strings.TrimSuffix(strings.TrimPrefix(repoURL, "git@github.com:"), ".git")
	}

	fmt.Printf("当前版本: %s\n", buildinfo.Version)
	fmt.Printf("检查新版本: %s/releases/latest\n", repoURL)
	fmt.Println()
	fmt.Println("更新方式: 下载最新 installer 重新运行即可（幂等覆盖）。")
	fmt.Printf("  %s/releases\n", repoURL)
	return nil
}

// --- uninstall ---

func newUninstallCmd() *cobra.Command {
	force := false
	cmd := &cobra.Command{
		Use:   "uninstall",
		Short: "卸载：销毁 VM → 删除数据目录 → 撤销 PATH",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runUninstall(force)
		},
	}
	cmd.Flags().BoolVar(&force, "force", false, "跳过确认直接卸载")
	return cmd
}

func runUninstall(force bool) error {
	dataRoot := paths.DataRoot()
	binDir := paths.BinDir()
	metaPath := paths.MetaPath()

	if _, err := os.Stat(dataRoot); os.IsNotExist(err) {
		fmt.Println("已是干净状态，无需卸载。")
		return nil
	}

	if !force {
		fmt.Printf("⚠ 即将卸载 %s\n", buildinfo.AppName)
		fmt.Printf("  - 销毁 VM\n")
		fmt.Printf("  - 删除 %s\n", dataRoot)
		fmt.Printf("  - 撤销 PATH 修改\n")
		fmt.Print("确认? [y/N] ")
		var answer string
		fmt.Scanln(&answer)
		if !strings.EqualFold(answer, "y") && !strings.EqualFold(answer, "yes") {
			fmt.Println("已取消")
			return nil
		}
	}

	// Step 1: Destroy VM
	fmt.Println("[1/3] 销毁 VM...")
	if err := runner.RunScript("destroy", "-y"); err != nil {
		fmt.Printf("⚠ 销毁 VM 失败: %v\n", err)
		if !force {
			fmt.Print("是否继续卸载? [y/N] ")
			var answer string
			fmt.Scanln(&answer)
			if !strings.EqualFold(answer, "y") {
				return fmt.Errorf("卸载中止")
			}
		}
	}

	// Step 2: Remove PATH
	fmt.Println("[2/3] 撤销 PATH...")
	removed, err := pathmgr.RemoveFromPath(binDir)
	if err != nil {
		fmt.Printf("⚠ PATH 清理部分失败: %v\n", err)
	}
	if len(removed) > 0 {
		fmt.Printf("  ✓ 已清理: %s\n", strings.Join(removed, ", "))
	}

	// Step 3: Self-delete via helper
	fmt.Println("[3/3] 删除数据目录...")

	// Read meta for verification
	_ = metaPath

	if runtime.GOOS == "windows" {
		selfDeleteWindows(dataRoot)
	} else {
		selfDeleteUnix(dataRoot)
	}

	// Verify
	if _, err := os.Stat(dataRoot); os.IsNotExist(err) {
		fmt.Printf("\n✓ %s 卸载完成！\n", buildinfo.AppName)
	} else {
		fmt.Printf("\n⚠ 数据目录可能未完全删除。请手动执行:\n")
		fmt.Printf("    rm -rf %s\n", dataRoot)
		return fmt.Errorf("卸载不完整")
	}
	return nil
}

func selfDeleteUnix(dataRoot string) {
	// On Unix, a running binary can delete its own directory
	if err := os.RemoveAll(dataRoot); err != nil {
		fmt.Printf("⚠ 删除失败: %v\n", err)
		fmt.Printf("请手动执行: rm -rf %s\n", dataRoot)
	}
}

func selfDeleteWindows(dataRoot string) {
	// On Windows, copy self to temp and use cmd /c to delete after exit
	tmpDir := os.TempDir()
	helper := filepath.Join(tmpDir, buildinfo.AppName+"-uninstall.cmd")
	script := fmt.Sprintf(`@echo off
ping 127.0.0.1 -n 3 >nul
rmdir /s /q "%s"
del "%%~f0"
`, dataRoot)
	if err := os.WriteFile(helper, []byte(script), 0o644); err != nil {
		fmt.Printf("⚠ 创建卸载助手失败: %v\n", err)
		fmt.Printf("请手动删除: %s\n", dataRoot)
		return
	}
	c := exec.Command("cmd", "/c", "start", "/min", helper)
	_ = c.Start()
}

func validateResourceChange(key, value string) error {
	resourceKeys := map[string]string{
		"VM_CPUS":      buildinfo.DefaultVMCPUs,
		"VM_MEMORY":    buildinfo.DefaultVMMemory,
		"VM_DISK_SIZE": buildinfo.DefaultVMDiskSize,
	}
	minStr, isResource := resourceKeys[key]
	if !isResource {
		return nil
	}

	newVal, err := strconv.Atoi(value)
	if err != nil {
		return nil
	}

	cfg, _ := loadConfig()
	enforce := buildinfo.DefaultEnforceResourceLimit == "1"
	if cfg != nil {
		if v := cfgVal(cfg, "ENFORCE_RESOURCE_LIMIT"); v == "0" {
			enforce = false
		}
	}

	if enforce {
		minVal, _ := strconv.Atoi(minStr)
		if key == "VM_CPUS" && newVal == 0 {
			// 0=auto is always allowed
		} else if minVal > 0 && newVal < minVal {
			return fmt.Errorf("资源下限保护: %s 不能低于构建时默认值 %d（当前设置: %s）\n"+
				"  如需解除限制，请先执行: %s config set ENFORCE_RESOURCE_LIMIT 0",
				key, minVal, value, buildinfo.AppName)
		}
	}

	hi, err := hostinfo.Get()
	if err != nil {
		return nil
	}

	switch key {
	case "VM_CPUS":
		if newVal > 0 && newVal > hi.LogicalCPUs {
			return fmt.Errorf("VM CPU %d 核超过宿主机可用 %d 核", newVal, hi.LogicalCPUs)
		}
	case "VM_MEMORY":
		if newVal > int(hi.TotalMemoryMB) {
			return fmt.Errorf("VM 内存 %d MB 超过宿主机总内存 %d MB", newVal, hi.TotalMemoryMB)
		}
	case "VM_DISK_SIZE":
		dataDir := ""
		if cfg != nil {
			dataDir = cfgVal(cfg, "DATA_DIR")
		}
		if dataDir != "" {
			if availGB, e := hostinfo.DiskAvailGB(dataDir); e == nil {
				if newVal > int(availGB) {
					return fmt.Errorf("VM 磁盘 %d GB 超过可用空间 %d GB（%s）", newVal, availGB, dataDir)
				}
			}
		}
	}

	return nil
}

// --- helpers ---

func loadConfig() (map[string]string, error) {
	return config.ReadEnv(paths.ConfigEnvPath())
}

func cfgVal(cfg map[string]string, key string) string {
	if v, ok := cfg[key]; ok && v != "" {
		return v
	}
	if m, ok := config.KnownKeys[key]; ok {
		return m.DefaultValue
	}
	return ""
}

func ensureVMRunning() (map[string]string, error) {
	cfg, err := loadConfig()
	if err != nil {
		return nil, fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
	}
	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		return nil, fmt.Errorf("VM 未运行。请先执行: %s setup", buildinfo.AppName)
	}
	return cfg, nil
}

func knownHostsDevNull() string {
	if runtime.GOOS == "windows" {
		return "NUL"
	}
	return "/dev/null"
}

func resolveSSHEndpoint(cfg map[string]string) (host, port string) {
	if runtime.GOOS == "windows" {
		return "127.0.0.1", "2222"
	}
	return "127.0.0.1", "22"
}

func saveConfigSnapshot() {
	cfgPath := paths.ConfigEnvPath()
	snapPath := paths.ConfigSnapshotPath()
	if _, err := os.Stat(cfgPath); err == nil {
		_ = config.SaveSnapshot(cfgPath, snapPath)
	}
}
