package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/meta"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
	"github.com/SuLinXin66/vm-autoinstaller/internal/pathmgr"
)

//go:embed staging/*
var staging embed.FS

func main() {
	fmt.Printf("%s installer v%s\n\n", buildinfo.AppName, buildinfo.Version)

	dataRoot := paths.DataRoot()
	repoDir := paths.RepoDir()
	binDir := paths.BinDir()
	cliPath := paths.CLIPath()
	metaPath := paths.MetaPath()
	configPath := paths.ConfigEnvPath()
	configExample := paths.ConfigEnvExamplePath()

	steps := 4
	step := 0

	// Step 1: Extract repo (scripts)
	step++
	fmt.Printf("[%d/%d] 释放脚本到 %s ...\n", step, steps, repoDir)
	if err := extractDir("staging", repoDir, []string{"_cli"}); err != nil {
		die("释放脚本失败: %v", err)
	}
	fmt.Println("  ✓ 完成")

	// Step 2: Extract CLI binary
	step++
	fmt.Printf("[%d/%d] 释放 CLI 到 %s ...\n", step, steps, cliPath)
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		die("创建 bin 目录失败: %v", err)
	}
	cliBinName := buildinfo.AppName
	if runtime.GOOS == "windows" {
		cliBinName += ".exe"
	}
	cliData, err := staging.ReadFile("staging/_cli/" + cliBinName)
	if err != nil {
		die("读取 CLI 二进制失败: %v", err)
	}
	perm := os.FileMode(0o755)
	if runtime.GOOS == "windows" {
		perm = 0o644
	}
	if err := os.WriteFile(cliPath, cliData, perm); err != nil {
		die("写入 CLI 失败: %v", err)
	}
	fmt.Println("  ✓ 完成")

	// Step 3: PATH
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

	// Step 4: config.env + meta
	step++
	fmt.Printf("[%d/%d] 写入元数据 ...\n", step, steps)
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		if exData, exErr := os.ReadFile(configExample); exErr == nil {
			_ = os.WriteFile(configPath, exData, 0o644)
			fmt.Println("  ✓ 已从模板创建 config.env")
		}
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
		die("写入 meta 失败: %v", err)
	}
	fmt.Println("  ✓ 完成")

	fmt.Println()
	fmt.Printf("✓ %s 安装完成！\n", buildinfo.AppName)
	fmt.Printf("  数据目录: %s\n", dataRoot)
	fmt.Printf("  CLI 路径: %s\n", cliPath)
	fmt.Println()

	printRestartHint(modified)

	if isDoubleClicked() {
		fmt.Print("请按回车键退出...")
		var b [1]byte
		os.Stdin.Read(b[:])
	}
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

		perm := os.FileMode(0o644)
		if strings.HasSuffix(path, ".sh") {
			perm = 0o755
		}
		return os.WriteFile(dst, data, perm)
	})
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

func isDoubleClicked() bool {
	if runtime.GOOS != "windows" {
		return false
	}
	// On Windows, check if parent process count suggests double-click
	// A simple heuristic: if stdin is not a terminal pipe
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0 && os.Getenv("PROMPT") == "" && os.Getenv("PSModulePath") == ""
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "错误: "+format+"\n", args...)
	os.Exit(1)
}
