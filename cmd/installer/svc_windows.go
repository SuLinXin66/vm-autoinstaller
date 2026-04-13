//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/SuLinXin66/vm-autoinstaller/internal/winsvc"
)

func ensureElevated() bool { return false }

func stopServiceBeforeCLI() {}

// installAndStartService performs all privileged operations in a single
// elevated PowerShell invocation (one UAC prompt):
//  1. Stop the old service (releases file lock on the CLI binary)
//  2. Swap the .new binary into the final path
//  3. Run "kvm-ubuntu _svc-install" to register + start the service
func installAndStartService(cliPath string) {
	tmpCli := cliPath + ".new"
	logFile := filepath.Join(os.TempDir(), "kvm-ubuntu-svc-install.log")
	os.Remove(logFile)

	if _, err := os.Stat(tmpCli); os.IsNotExist(err) {
		runElevatedInstall(cliPath, "", logFile)
		return
	}

	runElevatedInstall(cliPath, tmpCli, logFile)
}

// runElevatedInstall writes a temp .ps1 script, elevates it via
// Start-Process -Verb RunAs, and checks the result.
// If tmpCli is non-empty, the script will swap it into cliPath first.
func runElevatedInstall(cliPath, tmpCli, logFile string) {
	fmt.Println("  安装提权服务（将弹出 UAC 确认框）...")

	svcName := winsvc.ServiceName()
	scriptFile := filepath.Join(os.TempDir(), "kvm-ubuntu-svc-install.ps1")

	var sb strings.Builder
	sb.WriteString("$ErrorActionPreference = 'Continue'\n")
	sb.WriteString(fmt.Sprintf("$log = '%s'\n", logFile))
	sb.WriteString("'=== svc-install start ===' | Out-File $log -Encoding utf8\n")

	// Stop old service if running
	sb.WriteString(fmt.Sprintf("$svcName = '%s'\n", svcName))
	sb.WriteString("$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue\n")
	sb.WriteString("if ($svc -and $svc.Status -ne 'Stopped') {\n")
	sb.WriteString("  Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue\n")
	sb.WriteString("  Start-Sleep -Seconds 2\n")
	sb.WriteString("  'stopped old service' | Out-File $log -Append -Encoding utf8\n")
	sb.WriteString("}\n")

	// Swap binary if there's a .new file
	if tmpCli != "" {
		sb.WriteString(fmt.Sprintf("$tmp = '%s'\n", tmpCli))
		sb.WriteString(fmt.Sprintf("$dst = '%s'\n", cliPath))
		sb.WriteString("if (Test-Path $tmp) {\n")
		sb.WriteString("  Copy-Item $tmp $dst -Force\n")
		sb.WriteString("  Remove-Item $tmp -Force -ErrorAction SilentlyContinue\n")
		sb.WriteString("  'swapped binary' | Out-File $log -Append -Encoding utf8\n")
		sb.WriteString("}\n")
	}

	// Register and start service
	sb.WriteString(fmt.Sprintf("& '%s' '_svc-install' 2>&1 | Out-File $log -Append -Encoding utf8\n", cliPath))
	sb.WriteString("\"exit_code: $LASTEXITCODE\" | Out-File $log -Append -Encoding utf8\n")
	sb.WriteString("exit $LASTEXITCODE\n")

	if err := os.WriteFile(scriptFile, []byte(sb.String()), 0644); err != nil {
		fmt.Printf("  ⚠ 无法写入临时脚本: %v\n", err)
		return
	}
	defer os.Remove(scriptFile)

	// Elevate via Start-Process -Verb RunAs with -File (avoids all quoting issues)
	psCmd := fmt.Sprintf(
		`$p = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%s' -Verb RunAs -Wait -WindowStyle Hidden -PassThru; exit $p.ExitCode`,
		scriptFile,
	)
	cmd := exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", psCmd)
	err := cmd.Run()

	if err != nil {
		fmt.Printf("  ⚠ 提权操作失败: %v\n", err)
		printSvcInstallLog(logFile)
		if tmpCli != "" {
			if _, se := os.Stat(tmpCli); se == nil {
				if re := os.Rename(tmpCli, cliPath); re == nil {
					fmt.Println("  ✓ CLI 已写入（服务未安装，将降级为直接执行模式）")
				} else {
					fmt.Printf("  ⚠ CLI 文件被锁定，请手动停止旧服务后重试\n")
				}
			}
		}
		return
	}

	os.Remove(tmpCli)

	if winsvc.IsInstalled() {
		fmt.Println("  ✓ 提权服务已安装并启动")
	} else {
		fmt.Println("  ⚠ 服务注册未成功")
		printSvcInstallLog(logFile)
		fmt.Println("  提示: CLI 将降级为直接执行模式")
	}
}

func printSvcInstallLog(logFile string) {
	data, err := os.ReadFile(logFile)
	if err != nil {
		fmt.Println("  （无诊断日志）")
		return
	}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			fmt.Printf("    %s\n", line)
		}
	}
}
