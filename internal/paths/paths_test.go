package paths

import (
	"runtime"
	"strings"
	"testing"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
)

func TestDataRootContainsAppName(t *testing.T) {
	root := DataRoot()
	if !strings.Contains(root, buildinfo.AppName) {
		t.Errorf("DataRoot() = %q, should contain %q", root, buildinfo.AppName)
	}
}

func TestCLIPathExtension(t *testing.T) {
	p := CLIPath()
	if runtime.GOOS == "windows" {
		if !strings.HasSuffix(p, ".exe") {
			t.Errorf("CLIPath() = %q, should end with .exe on Windows", p)
		}
	} else {
		if strings.HasSuffix(p, ".exe") {
			t.Errorf("CLIPath() = %q, should not end with .exe on non-Windows", p)
		}
	}
}

func TestRepoDir(t *testing.T) {
	rd := RepoDir()
	if !strings.HasSuffix(rd, "repo") {
		t.Errorf("RepoDir() = %q, should end with 'repo'", rd)
	}
}

func TestScriptDir(t *testing.T) {
	sd := ScriptDir()
	if runtime.GOOS == "windows" {
		if !strings.HasSuffix(sd, "windows") {
			t.Errorf("ScriptDir() = %q, should end with 'windows'", sd)
		}
	} else {
		if !strings.HasSuffix(sd, "linux") {
			t.Errorf("ScriptDir() = %q, should end with 'linux'", sd)
		}
	}
}
