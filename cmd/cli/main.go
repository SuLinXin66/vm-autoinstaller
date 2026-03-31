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

	"github.com/spf13/cobra"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/config"
	"github.com/SuLinXin66/vm-autoinstaller/internal/meta"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
	"github.com/SuLinXin66/vm-autoinstaller/internal/pathmgr"
	"github.com/SuLinXin66/vm-autoinstaller/internal/runner"
	"github.com/SuLinXin66/vm-autoinstaller/internal/table"
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
		newStatusCmd(),
		newDestroyCmd(),
		newProvisionCmd(),
		newSSHCmd(),
		newChromeCmd(),
		newExecCmd(),
		newCpCmd(),
		newConfigCmd(),
		newInfoCmd(),
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
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
	}
	vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
	_ = vmName

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
			cfg, err := loadConfig()
			if err != nil {
				return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
			}
			user := cfgVal(cfg, "VM_USER", "wpsweb")
			dataDir := cfgVal(cfg, "DATA_DIR", defaultDataDir())
			keyPath := filepath.Join(dataDir, "id_ed25519")

			sshHost, sshPort := resolveSSHEndpoint(cfg)

			sshArgs := []string{
				"-o", "StrictHostKeyChecking=no",
				"-o", "UserKnownHostsFile=/dev/null",
				"-o", "LogLevel=ERROR",
				"-p", sshPort,
			}
			if _, err := os.Stat(keyPath); err == nil {
				sshArgs = append(sshArgs, "-i", keyPath)
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
			cfg, err := loadConfig()
			if err != nil {
				return fmt.Errorf("配置未找到。请先运行: %s setup", buildinfo.AppName)
			}
			user := cfgVal(cfg, "VM_USER", "wpsweb")
			dataDir := cfgVal(cfg, "DATA_DIR", defaultDataDir())
			keyPath := filepath.Join(dataDir, "id_ed25519")
			sshHost, sshPort := resolveSSHEndpoint(cfg)

			scpArgs := []string{
				"-o", "StrictHostKeyChecking=no",
				"-o", "UserKnownHostsFile=/dev/null",
				"-o", "LogLevel=ERROR",
				"-P", sshPort,
			}
			if _, err := os.Stat(keyPath); err == nil {
				scpArgs = append(scpArgs, "-i", keyPath)
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

func showConfig() error {
	cfgPath := paths.ConfigEnvPath()
	env, err := config.ReadEnv(cfgPath)
	if err != nil {
		return fmt.Errorf("无法读取配置: %v", err)
	}

	pending := config.PendingChanges(cfgPath, paths.ConfigSnapshotPath())
	hasPending := len(pending) > 0

	t := table.New("键", "当前值", "状态", "说明", "备注")

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
		status := table.Colorize(table.Green, "✓ 已生效")

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
			status = table.Colorize(table.BrightRed, "⚠ 待生效")
			val = table.Colorize(table.BrightRed, val)
			if oldVal != "" {
				remark = "生效值: " + oldVal
			} else {
				remark = "新增，尚未生效"
			}
			if known && m.EffectLevel != config.LevelNone {
				remark += " (" + m.EffectLevel.String() + ")"
			}
		}

		t.AddRow(key, val, status, desc, remark)
	}

	fmt.Print(t.Render())

	if hasPending {
		fmt.Println()
		fmt.Println(table.Colorize(table.BrightRed, "⚠ 有配置已修改但未生效，请执行以下命令使其生效:"))
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
		fmt.Println(table.Colorize(table.Green, "✓ 所有配置均已生效，无待生效变更。"))
		return nil
	}

	current, _ := config.ReadEnv(cfgPath)
	t := table.New("键", "当前值(未生效)", "生效中的值", "所需操作")
	for _, k := range config.SortedKeys(pending) {
		cur := current[k]
		old := pending[k]
		action := ""
		if m, ok := config.KnownKeys[k]; ok && m.EffectLevel != config.LevelNone {
			action = m.EffectLevel.String()
		}
		t.AddRow(k,
			table.Colorize(table.BrightRed, cur),
			old,
			action,
		)
	}
	fmt.Print(t.Render())
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
	t := table.New("项目", "值")
	t.AddRow("应用名称", buildinfo.AppName)
	t.AddRow("CLI 版本", buildinfo.Version)
	t.AddRow("仓库地址", buildinfo.RepoURL)
	t.AddRow("分支", buildinfo.Branch)
	t.AddRow("数据目录", paths.DataRoot())
	t.AddRow("脚本目录", paths.ScriptDir())

	metaPath := paths.MetaPath()
	if m, err := meta.Load(metaPath); err == nil {
		t.AddRow("Bundle 版本", m.BundleVersion)
	}

	cfgPath := paths.ConfigEnvPath()
	cfg, cfgErr := config.ReadEnv(cfgPath)
	if cfgErr == nil {
		vmName := cfgVal(cfg, "VM_NAME", "ubuntu-server")
		dataDir := cfgVal(cfg, "DATA_DIR", defaultDataDir())
		t.AddRow("VM 名称", vmName)
		t.AddRow("VM 数据目录", dataDir)

		if runtime.GOOS == "windows" {
			addVBoxInfo(t, vmName)
		} else {
			addKVMInfo(t, vmName)
		}
	}

	fmt.Print(t.Render())
	return nil
}

// --- VM resource helpers (KVM/libvirt) ---

func runVirsh(args ...string) (string, error) {
	allArgs := append([]string{"-c", "qemu:///system"}, args...)
	out, err := exec.Command("virsh", allArgs...).CombinedOutput()
	if err == nil {
		return string(out), nil
	}
	sudoArgs := append([]string{"-n", "virsh"}, allArgs...)
	out, err = exec.Command("sudo", sudoArgs...).CombinedOutput()
	if err == nil {
		return string(out), nil
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

func addKVMInfo(t *table.Table, vmName string) {
	out, err := runVirsh("dominfo", vmName)
	if err != nil {
		t.AddRow("VM 状态", table.Colorize(table.BrightRed, "未创建"))
		return
	}

	info := parseVirshKV(out)
	state := info["State"]

	switch state {
	case "running":
		t.AddRow("VM 状态", table.Colorize(table.Green, "运行中"))
	case "shut off":
		t.AddRow("VM 状态", table.Colorize(table.Yellow, "已关机"))
		return
	case "paused":
		t.AddRow("VM 状态", table.Colorize(table.Yellow, "已暂停"))
		return
	default:
		t.AddRow("VM 状态", state)
		return
	}

	if ip := getVirshIP(vmName); ip != "" {
		t.AddRow("VM IP", ip)
	}

	if cpus := info["CPU(s)"]; cpus != "" {
		t.AddRow("VM CPU", cpus+" 核")
	}
	if cpuTime := info["CPU time"]; cpuTime != "" {
		t.AddRow("VM CPU 时间", cpuTime)
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
	t.AddRow("VM 内存", memStr)
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

func addVBoxInfo(t *table.Table, vmName string) {
	out, err := exec.Command("VBoxManage", "showvminfo", vmName, "--machinereadable").CombinedOutput()
	if err != nil {
		t.AddRow("VM 状态", table.Colorize(table.BrightRed, "未创建"))
		return
	}

	info := make(map[string]string)
	for _, line := range strings.Split(string(out), "\n") {
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			info[parts[0]] = strings.Trim(parts[1], "\"")
		}
	}

	switch info["VMState"] {
	case "running":
		t.AddRow("VM 状态", table.Colorize(table.Green, "运行中"))
	case "poweroff":
		t.AddRow("VM 状态", table.Colorize(table.Yellow, "已关机"))
		return
	default:
		t.AddRow("VM 状态", info["VMState"])
		return
	}

	if cpus := info["cpus"]; cpus != "" {
		t.AddRow("VM CPU", cpus+" 核")
	}
	if mem := info["memory"]; mem != "" {
		t.AddRow("VM 内存", mem+" MB")
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

// --- helpers ---

func loadConfig() (map[string]string, error) {
	return config.ReadEnv(paths.ConfigEnvPath())
}

func cfgVal(cfg map[string]string, key, def string) string {
	if v, ok := cfg[key]; ok && v != "" {
		return v
	}
	return def
}

func defaultDataDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".kvm-ubuntu")
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
