package runner

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"time"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
)

func RunScript(name string, args ...string) error {
	scriptDir := paths.ScriptDir()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	switch runtime.GOOS {
	case "windows":
		return runWindows(ctx, scriptDir, name, args...)
	default:
		return runUnix(ctx, scriptDir, name, args...)
	}
}

func runUnix(ctx context.Context, scriptDir, name string, args ...string) error {
	script := filepath.Join(scriptDir, name+".sh")
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("脚本不存在: %s", script)
	}
	cmd := exec.CommandContext(ctx, "bash", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), "APP_NAME="+buildinfo.AppName)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	configProcessGroup(cmd)
	cmd.Cancel = func() error {
		return killProcessGroup(cmd)
	}
	cmd.WaitDelay = 5 * time.Second
	return cmd.Run()
}

func runWindows(ctx context.Context, scriptDir, name string, args ...string) error {
	ps1 := filepath.Join(scriptDir, name+".ps1")
	if _, err := os.Stat(ps1); err != nil {
		return fmt.Errorf("脚本不存在: %s", ps1)
	}
	psArgs := []string{
		"-ExecutionPolicy", "Bypass",
		"-NoProfile",
		"-File", ps1,
	}
	psArgs = append(psArgs, args...)
	cmd := exec.CommandContext(ctx, "powershell.exe", psArgs...)
	cmd.Env = append(os.Environ(), "APP_NAME="+buildinfo.AppName)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.WaitDelay = 5 * time.Second
	return cmd.Run()
}
