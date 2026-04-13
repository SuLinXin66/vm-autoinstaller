package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/gookit/color"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/config"
	"github.com/SuLinXin66/vm-autoinstaller/internal/hostinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/meta"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
	"github.com/SuLinXin66/vm-autoinstaller/internal/pathmgr"
	"github.com/SuLinXin66/vm-autoinstaller/internal/share"
)

//go:embed all:staging
var staging embed.FS

func main() {
	pause := isDoubleClicked()
	err := run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
	}
	if pause {
		fmt.Println()
		fmt.Print("请按回车键退出...")
		var b [1]byte
		os.Stdin.Read(b[:])
	}
	if err != nil {
		os.Exit(1)
	}
}

func run() error {
	fmt.Printf("%s installer v%s\n\n", buildinfo.AppName, buildinfo.Version)

	if err := checkResources(); err != nil {
		return err
	}

	dataRoot := paths.DataRoot()
	repoDir := paths.RepoDir()
	binDir := paths.BinDir()
	cliPath := paths.CLIPath()
	metaPath := paths.MetaPath()
	configPath := paths.ConfigEnvPath()
	configExample := paths.ConfigEnvExamplePath()

	compDir := paths.CompletionDir()

	steps := 5
	step := 0

	step++
	fmt.Printf("[%d/%d] 释放脚本到 %s ...\n", step, steps, repoDir)
	if err := extractDir("staging", repoDir, []string{"_cli"}); err != nil {
		return fmt.Errorf("释放脚本失败: %v", err)
	}
	fmt.Println("  ✓ 完成")

	step++
	fmt.Printf("[%d/%d] 释放 CLI 到 %s ...\n", step, steps, cliPath)
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return fmt.Errorf("创建 bin 目录失败: %v", err)
	}
	cliBinName := buildinfo.AppName
	if runtime.GOOS == "windows" {
		cliBinName += ".exe"
	}
	cliData, err := staging.ReadFile("staging/_cli/" + cliBinName)
	if err != nil {
		return fmt.Errorf("读取 CLI 二进制失败: %v", err)
	}
	perm := os.FileMode(0o755)
	if runtime.GOOS == "windows" {
		perm = 0o644
	}
	// On Windows the old service may hold a lock on cliPath.
	// Write to a temp file first; installAndStartService will
	// elevate, stop the service, swap the file, then re-register.
	writePath := cliPath
	if runtime.GOOS == "windows" {
		writePath = cliPath + ".new"
	}
	if err := os.WriteFile(writePath, cliData, perm); err != nil {
		return fmt.Errorf("写入 CLI 失败: %v", err)
	}
	installAndStartService(cliPath)
	fmt.Println("  ✓ 完成")

	step++
	fmt.Printf("[%d/%d] 生成 shell 补全脚本 ...\n", step, steps)
	if err := generateCompletions(cliPath, compDir); err != nil {
		fmt.Printf("  ⚠ 补全脚本生成部分失败: %v\n", err)
	} else {
		fmt.Println("  ✓ 完成")
	}

	step++
	fmt.Printf("[%d/%d] 配置 PATH ...\n", step, steps)
	modified, err := pathmgr.AddToPath(binDir)
	if err != nil {
		fmt.Printf("  ⚠ PATH 写入部分失败: %v\n", err)
	}
	if len(modified) > 0 {
		fmt.Printf("  ✓ 已写入: %s\n", strings.Join(modified, ", "))
	} else {
		fmt.Println("  ✓ PATH 已包含，无需修改")
	}

	step++
	fmt.Printf("[%d/%d] 写入元数据 ...\n", step, steps)
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		if exData, exErr := os.ReadFile(configExample); exErr == nil {
			_ = os.WriteFile(configPath, exData, 0o644)
			fmt.Println("  ✓ 已从模板创建 config.env")
		}
	} else {
		repairConfigEnv(configPath, configExample)
	}
	m := &meta.InstallMeta{
		AppName:       buildinfo.AppName,
		CLIVersion:    buildinfo.Version,
		BundleVersion: buildinfo.Version,
		RepoURL:       buildinfo.RepoURL,
		Branch:        buildinfo.Branch,
		PathEntries:   modified,
	}
	if err := m.Save(metaPath); err != nil {
		return fmt.Errorf("写入 meta 失败: %v", err)
	}
	fmt.Println("  ✓ 完成")

	// Reconcile resources: user values below build.env defaults → reset
	reconcileResources()

	// Reconcile builtin shares
	if buildinfo.DefaultBuiltinShares != "" {
		fmt.Println()
		fmt.Println("内置共享目录对账:")
		vmUser := getDefault("VM_USER", buildinfo.DefaultVMUser)
		res, err := share.ReconcileBuiltinShares(buildinfo.DefaultBuiltinShares, vmUser, true)
		if err != nil {
			return fmt.Errorf("内置共享目录对账失败: %v", err)
		}
		for _, a := range res.Added {
			color.Green.Printf("  + 新增: %s\n", a)
		}
		for _, u := range res.Updated {
			color.Yellow.Printf("  ~ 更新: %s\n", u)
		}
		for _, r := range res.Restored {
			color.Yellow.Printf("  ↻ 恢复: %s\n", r)
		}
		for _, d := range res.Removed {
			color.Gray.Printf("  - 移除旧版: %s\n", d)
		}
		if !res.HasChanges() {
			fmt.Println("  ✓ 已对齐，无需变更")
		}
	}

	fmt.Println()
	fmt.Printf("✓ %s 安装完成！\n", buildinfo.AppName)
	fmt.Printf("  数据目录: %s\n", dataRoot)
	fmt.Printf("  CLI 路径: %s\n", cliPath)
	fmt.Println()

	printRestartHint(modified)
	return nil
}

func extractDir(srcRoot, dstRoot string, skip []string) error {
	return fs.WalkDir(staging, srcRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		rel, _ := filepath.Rel(srcRoot, path)
		if rel == "." {
			return os.MkdirAll(dstRoot, 0o755)
		}

		topDir := strings.SplitN(rel, string(filepath.Separator), 2)[0]
		// Also handle embedded paths using '/'
		if strings.Contains(rel, "/") {
			topDir = strings.SplitN(rel, "/", 2)[0]
		}
		for _, s := range skip {
			if topDir == s {
				if d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
		}

		dst := filepath.Join(dstRoot, filepath.FromSlash(rel))

		if d.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}

		data, readErr := staging.ReadFile(path)
		if readErr != nil {
			return readErr
		}

		// PowerShell 5.1 reads files using system default encoding (GBK on
		// Chinese Windows). Prepend UTF-8 BOM so PS correctly decodes non-ASCII.
		if (strings.HasSuffix(path, ".ps1") || strings.HasSuffix(path, ".psm1")) &&
			!hasBOM(data) {
			data = append([]byte{0xEF, 0xBB, 0xBF}, data...)
		}

		perm := os.FileMode(0o644)
		if strings.HasSuffix(path, ".sh") {
			perm = 0o755
		}
		return os.WriteFile(dst, data, perm)
	})
}

func generateCompletions(cliPath, compDir string) error {
	if err := os.MkdirAll(compDir, 0o755); err != nil {
		return fmt.Errorf("创建目录失败: %w", err)
	}

	type shellDef struct {
		arg string // argument passed to _gen-completion
		ext string // file extension for CompletionFilePath
	}
	shells := []shellDef{
		{"bash", "bash"},
		{"zsh", "zsh"},
	}
	if runtime.GOOS == "windows" {
		shells = []shellDef{
			{"powershell", "ps1"},
		}
	}

	var firstErr error
	for _, s := range shells {
		out, err := exec.Command(cliPath, "_gen-completion", s.arg).Output()
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %w", s.arg, err)
			}
			continue
		}
		dst := paths.CompletionFilePath(s.ext)
		if err := os.WriteFile(dst, out, 0o644); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("写入 %s 失败: %w", dst, err)
			}
		}
	}
	return firstErr
}

func printRestartHint(modified []string) {
	if runtime.GOOS == "windows" {
		fmt.Println("⚡ 请重新打开 命令行/PowerShell 窗口以使 PATH 生效。")
		return
	}
	if len(modified) == 0 {
		return
	}
	fmt.Println("⚡ 请重新打开终端，或执行以下命令使 PATH 生效:")
	for _, f := range modified {
		fmt.Printf("    source %s\n", f)
	}
}

func hasBOM(data []byte) bool {
	return len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF
}

func repairConfigEnv(configPath, examplePath string) {
	cfg, err := config.ReadEnv(configPath)
	if err != nil {
		return
	}
	dataDir := cfg["DATA_DIR"]
	if dataDir == "" {
		return
	}
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(dataDir, home) {
		return
	}
	if strings.HasPrefix(dataDir, "/") || strings.HasPrefix(dataDir, "$") || strings.HasPrefix(dataDir, "~") {
		return
	}
	// DATA_DIR looks broken (e.g. PID + {HOME}), reset from template
	exCfg, err := config.ReadEnv(examplePath)
	if err != nil {
		return
	}
	if exDir, ok := exCfg["DATA_DIR"]; ok && exDir != "" {
		_ = config.WriteValue(configPath, "DATA_DIR", exDir)
		color.Yellow.Printf("  ⚠ DATA_DIR 异常，已从模板修复: %s\n", exDir)
	}
}

func checkResources() error {
	hi, err := hostinfo.Get()
	if err != nil {
		color.Yellow.Printf("⚠ 无法获取宿主机信息: %v，跳过资源检查\n\n", err)
		return nil
	}

	vmCPUs, _ := strconv.Atoi(getDefault("VM_CPUS", buildinfo.DefaultVMCPUs))
	vmMemMB, _ := strconv.Atoi(getDefault("VM_MEMORY", buildinfo.DefaultVMMemory))
	vmDiskGB, _ := strconv.Atoi(getDefault("VM_DISK_SIZE", buildinfo.DefaultVMDiskSize))

	if vmCPUs <= 0 {
		vmCPUs = hi.LogicalCPUs
	}

	fmt.Println("系统资源检查:")
	ok := true

	if hi.LogicalCPUs >= vmCPUs {
		color.Green.Printf("  ✓ CPU:    宿主机 %d 核 >= 需要 %d 核\n", hi.LogicalCPUs, vmCPUs)
	} else {
		color.LightRed.Printf("  ✗ CPU:    宿主机 %d 核 < 需要 %d 核\n", hi.LogicalCPUs, vmCPUs)
		ok = false
	}

	if int(hi.TotalMemoryMB) >= vmMemMB {
		color.Green.Printf("  ✓ 内存:   宿主机 %d MB >= 需要 %d MB\n", hi.TotalMemoryMB, vmMemMB)
	} else {
		color.LightRed.Printf("  ✗ 内存:   宿主机 %d MB < 需要 %d MB\n", hi.TotalMemoryMB, vmMemMB)
		ok = false
	}

	dataRoot := paths.DataRoot()
	needGB := vmDiskGB + 5
	availGB, diskErr := hostinfo.DiskAvailGB(dataRoot)
	if diskErr == nil {
		if int(availGB) >= needGB {
			color.Green.Printf("  ✓ 磁盘:   可用 %d GB >= 需要 %d GB\n", availGB, needGB)
		} else {
			color.LightRed.Printf("  ✗ 磁盘:   可用 %d GB < 需要 %d GB\n", availGB, needGB)
			ok = false
		}
	}

	fmt.Println()
	if !ok {
		return fmt.Errorf("宿主机资源不满足 VM 配置要求，请升级硬件")
	}
	return nil
}

func reconcileResources() {
	cfgPath := paths.ConfigEnvPath()
	cfg, err := config.ReadEnv(cfgPath)
	if err != nil {
		return
	}

	type resItem struct {
		Key      string
		Default  string
		Unit     string
	}
	items := []resItem{
		{"VM_CPUS", buildinfo.DefaultVMCPUs, "核"},
		{"VM_MEMORY", buildinfo.DefaultVMMemory, "MB"},
		{"VM_DISK_SIZE", buildinfo.DefaultVMDiskSize, "GB"},
	}

	for _, item := range items {
		minVal, _ := strconv.Atoi(item.Default)
		if minVal <= 0 {
			continue
		}
		userStr, exists := cfg[item.Key]
		if !exists || userStr == "" {
			_ = config.WriteValue(cfgPath, item.Key, item.Default)
			color.Yellow.Printf("  ⚠ %s 未设置，已初始化为默认值 %s %s\n", item.Key, item.Default, item.Unit)
			continue
		}
		userVal, _ := strconv.Atoi(userStr)
		if item.Key == "VM_CPUS" && userVal == 0 {
			continue // 0=auto, always valid
		}
		if userVal >= minVal {
			continue
		}
		_ = config.WriteValue(cfgPath, item.Key, item.Default)
		color.Yellow.Printf("  ⚠ %s (%s %s) 低于默认最低要求 (%d %s)，已重置为 %s\n",
			item.Key, userStr, item.Unit, minVal, item.Unit, item.Default)
	}
}

func getDefault(key, fallback string) string {
	cfgPath := paths.ConfigEnvPath()
	if cfg, err := config.ReadEnv(cfgPath); err == nil {
		if v, ok := cfg[key]; ok && v != "" {
			return v
		}
	}
	return fallback
}

