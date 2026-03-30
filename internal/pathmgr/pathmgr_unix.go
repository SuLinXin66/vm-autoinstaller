//go:build !windows

package pathmgr

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
)

func markerBegin() string { return fmt.Sprintf("# >>> %s >>>", buildinfo.AppName) }
func markerEnd() string   { return fmt.Sprintf("# <<< %s <<<", buildinfo.AppName) }

func exportLine(binDir string) string {
	return fmt.Sprintf("export PATH=\"%s:$PATH\"", binDir)
}

func completionLine(shell string) string {
	return fmt.Sprintf("eval \"$(%s completion %s)\"", buildinfo.AppName, shell)
}

func markerBlock(binDir, shell string) string {
	lines := []string{
		markerBegin(),
		exportLine(binDir),
	}
	if shell != "" {
		lines = append(lines, completionLine(shell))
	}
	lines = append(lines, markerEnd())
	return strings.Join(lines, "\n") + "\n"
}

type rcFile struct {
	path  string
	shell string // "bash", "zsh", or "" (no completion)
}

func shellRCFiles() []rcFile {
	home, _ := os.UserHomeDir()
	candidates := []rcFile{
		{filepath.Join(home, ".profile"), ""},
		{filepath.Join(home, ".bashrc"), "bash"},
		{filepath.Join(home, ".zshrc"), "zsh"},
	}
	var result []rcFile
	for _, f := range candidates {
		if _, err := os.Stat(f.path); err == nil {
			result = append(result, f)
		}
	}
	return result
}

func AddToPath(binDir string) ([]string, error) {
	files := shellRCFiles()
	var modified []string
	begin := markerBegin()

	for _, f := range files {
		data, err := os.ReadFile(f.path)
		if err != nil {
			continue
		}
		content := string(data)
		if strings.Contains(content, begin) {
			// Already present — rewrite the block to pick up any changes
			// (e.g. completion line added in a newer version)
			content = removeBlock(content, begin, markerEnd())
		}
		block := markerBlock(binDir, f.shell)
		content = strings.TrimRight(content, "\n") + "\n\n" + block
		if err := os.WriteFile(f.path, []byte(content), 0o644); err != nil {
			return modified, fmt.Errorf("写入 %s 失败: %w", f.path, err)
		}
		modified = append(modified, f.path)
	}
	return modified, nil
}

func removeBlock(content, begin, end string) string {
	lines := strings.Split(content, "\n")
	var result []string
	inBlock := false
	for _, line := range lines {
		if strings.TrimSpace(line) == begin {
			inBlock = true
			continue
		}
		if inBlock && strings.TrimSpace(line) == end {
			inBlock = false
			continue
		}
		if inBlock {
			continue
		}
		result = append(result, line)
	}
	return strings.Join(result, "\n")
}

func RemoveFromPath(_ string) ([]string, error) {
	files := shellRCFiles()
	var modified []string
	begin := markerBegin()
	end := markerEnd()

	for _, f := range files {
		data, err := os.ReadFile(f.path)
		if err != nil {
			continue
		}
		content := string(data)
		if !strings.Contains(content, begin) {
			continue
		}
		newContent := strings.TrimRight(removeBlock(content, begin, end), "\n") + "\n"
		if err := os.WriteFile(f.path, []byte(newContent), 0o644); err != nil {
			return modified, fmt.Errorf("写入 %s 失败: %w", f.path, err)
		}
		modified = append(modified, f.path)
	}
	return modified, nil
}
