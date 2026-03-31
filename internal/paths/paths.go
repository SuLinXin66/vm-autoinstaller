package paths

import (
	"os"
	"path/filepath"
	"runtime"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
)

func DataRoot() string {
	switch runtime.GOOS {
	case "windows":
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local")
		}
		return filepath.Join(base, buildinfo.AppName)
	default:
		home, _ := os.UserHomeDir()
		xdg := os.Getenv("XDG_DATA_HOME")
		if xdg == "" {
			xdg = filepath.Join(home, ".local", "share")
		}
		return filepath.Join(xdg, buildinfo.AppName)
	}
}

func BinDir() string {
	return filepath.Join(DataRoot(), "bin")
}

func CLIPath() string {
	name := buildinfo.AppName
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(BinDir(), name)
}

func RepoDir() string {
	return filepath.Join(DataRoot(), "repo")
}

func MetaPath() string {
	return filepath.Join(DataRoot(), ".install-meta.json")
}

func ConfigEnvPath() string {
	return filepath.Join(RepoDir(), "vm", "config.env")
}

func ConfigEnvExamplePath() string {
	return filepath.Join(RepoDir(), "vm", "config.env.example")
}

func ConfigSnapshotPath() string {
	return filepath.Join(DataRoot(), ".config-snapshot.env")
}

func CompletionDir() string {
	return filepath.Join(DataRoot(), "completions")
}

func CompletionFilePath(shell string) string {
	return filepath.Join(CompletionDir(), buildinfo.AppName+"."+shell)
}

func SharesPath() string {
	return filepath.Join(DataRoot(), "shares.json")
}

func ScriptDir() string {
	switch runtime.GOOS {
	case "windows":
		return filepath.Join(RepoDir(), "windows")
	default:
		return filepath.Join(RepoDir(), "linux")
	}
}
