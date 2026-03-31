package runner

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
)

func RunScript(name string, args ...string) error {
	scriptDir := paths.ScriptDir()
	switch runtime.GOOS {
	case "windows":
		return runWindows(scriptDir, name, args...)
	default:
		return runUnix(scriptDir, name, args...)
	}
}

func runUnix(scriptDir, name string, args ...string) error {
	script := filepath.Join(scriptDir, name+".sh")
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("脚本不存在: %s", script)
	}
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), "APP_NAME="+buildinfo.AppName)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runWindows(scriptDir, name string, args ...string) error {
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
	cmd := exec.Command("powershell.exe", psArgs...)
	cmd.Env = append(os.Environ(), "APP_NAME="+buildinfo.AppName)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
