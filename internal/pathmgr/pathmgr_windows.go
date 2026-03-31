//go:build windows

package pathmgr

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
	"golang.org/x/sys/windows/registry"
)

const envRegKey = `Environment`

func markerBegin() string { return fmt.Sprintf("# >>> %s >>>", buildinfo.AppName) }
func markerEnd() string   { return fmt.Sprintf("# <<< %s <<<", buildinfo.AppName) }

func AddToPath(binDir string) ([]string, error) {
	var modified []string

	// --- Registry PATH ---
	pathModified, err := addToRegistryPath(binDir)
	if err != nil {
		return nil, err
	}
	if pathModified {
		modified = append(modified, "HKCU\\Environment\\Path")
	}

	// --- PowerShell profile completion ---
	profiles := psProfilePaths()
	for _, p := range profiles {
		wrote, writeErr := writePSProfile(p)
		if writeErr != nil {
			continue
		}
		if wrote {
			modified = append(modified, p)
		}
	}

	return modified, nil
}

func RemoveFromPath(binDir string) ([]string, error) {
	var modified []string

	// --- Registry PATH ---
	pathRemoved, err := removeFromRegistryPath(binDir)
	if err == nil && pathRemoved {
		modified = append(modified, "HKCU\\Environment\\Path")
	}

	// --- PowerShell profile completion ---
	profiles := psProfilePaths()
	for _, p := range profiles {
		removed, rmErr := removePSProfileBlock(p)
		if rmErr == nil && removed {
			modified = append(modified, p)
		}
	}

	return modified, nil
}

// --- Registry PATH helpers ---

func addToRegistryPath(binDir string) (bool, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, envRegKey, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return false, fmt.Errorf("打开注册表失败: %w", err)
	}
	defer k.Close()

	current, _, err := k.GetStringValue("Path")
	if err != nil && err != registry.ErrNotExist {
		return false, fmt.Errorf("读取 PATH 失败: %w", err)
	}

	parts := strings.Split(current, ";")
	for _, p := range parts {
		if strings.EqualFold(strings.TrimSpace(p), binDir) {
			return false, nil
		}
	}

	newPath := current
	if newPath != "" && !strings.HasSuffix(newPath, ";") {
		newPath += ";"
	}
	newPath += binDir

	if err := k.SetStringValue("Path", newPath); err != nil {
		return false, err
	}
	return true, nil
}

func removeFromRegistryPath(binDir string) (bool, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, envRegKey, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return false, nil
	}
	defer k.Close()

	current, _, err := k.GetStringValue("Path")
	if err != nil {
		return false, nil
	}

	parts := strings.Split(current, ";")
	var kept []string
	found := false
	for _, p := range parts {
		if strings.EqualFold(strings.TrimSpace(p), binDir) {
			found = true
			continue
		}
		if strings.TrimSpace(p) != "" {
			kept = append(kept, p)
		}
	}
	if !found {
		return false, nil
	}

	if err := k.SetStringValue("Path", strings.Join(kept, ";")); err != nil {
		return false, err
	}
	return true, nil
}

// --- PowerShell profile helpers ---

func psProfilePaths() []string {
	home := os.Getenv("USERPROFILE")
	if home == "" {
		return nil
	}
	docs := filepath.Join(home, "Documents")
	return []string{
		// PowerShell 5.1 (Windows PowerShell, ships with Windows)
		filepath.Join(docs, "WindowsPowerShell", "Microsoft.PowerShell_profile.ps1"),
		// PowerShell 7+ (PowerShell Core)
		filepath.Join(docs, "PowerShell", "Microsoft.PowerShell_profile.ps1"),
	}
}

func psCompletionBlock() string {
	begin := markerBegin()
	end := markerEnd()
	ps1 := paths.CompletionFilePath("ps1")
	lines := []string{
		begin,
		fmt.Sprintf("if (Test-Path '%s') { . '%s' }", ps1, ps1),
		end,
	}
	return strings.Join(lines, "\n") + "\n"
}

func writePSProfile(profilePath string) (bool, error) {
	begin := markerBegin()
	block := psCompletionBlock()

	data, err := os.ReadFile(profilePath)
	if err != nil {
		if !os.IsNotExist(err) {
			return false, err
		}
		// Profile doesn't exist — only create it for PS 5.1 (always available)
		if !strings.Contains(profilePath, "WindowsPowerShell") {
			// PS 7+ might not be installed; skip to avoid creating empty dirs
			if _, statErr := os.Stat(filepath.Dir(profilePath)); os.IsNotExist(statErr) {
				return false, nil
			}
		}
		// Create profile directory and file
		if err := os.MkdirAll(filepath.Dir(profilePath), 0o755); err != nil {
			return false, err
		}
		return true, os.WriteFile(profilePath, []byte(block), 0o644)
	}

	content := string(data)
	if strings.Contains(content, begin) {
		// Already present — rewrite block to pick up changes
		content = removeBlockFromContent(content, begin, markerEnd())
	}
	content = strings.TrimRight(content, "\r\n") + "\n\n" + block
	return true, os.WriteFile(profilePath, []byte(content), 0o644)
}

func removePSProfileBlock(profilePath string) (bool, error) {
	data, err := os.ReadFile(profilePath)
	if err != nil {
		return false, nil
	}
	content := string(data)
	begin := markerBegin()
	if !strings.Contains(content, begin) {
		return false, nil
	}
	newContent := strings.TrimRight(removeBlockFromContent(content, begin, markerEnd()), "\r\n") + "\n"
	return true, os.WriteFile(profilePath, []byte(newContent), 0o644)
}

func removeBlockFromContent(content, begin, end string) string {
	lines := strings.Split(content, "\n")
	var result []string
	inBlock := false
	for _, line := range lines {
		trimmed := strings.TrimRight(line, "\r")
		if strings.TrimSpace(trimmed) == begin {
			inBlock = true
			continue
		}
		if inBlock && strings.TrimSpace(trimmed) == end {
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
