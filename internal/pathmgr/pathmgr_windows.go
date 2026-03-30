//go:build windows

package pathmgr

import (
	"fmt"
	"strings"

	"golang.org/x/sys/windows/registry"
)

const envRegKey = `Environment`

func AddToPath(binDir string) ([]string, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, envRegKey, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return nil, fmt.Errorf("打开注册表失败: %w", err)
	}
	defer k.Close()

	current, _, err := k.GetStringValue("Path")
	if err != nil && err != registry.ErrNotExist {
		return nil, fmt.Errorf("读取 PATH 失败: %w", err)
	}

	parts := strings.Split(current, ";")
	for _, p := range parts {
		if strings.EqualFold(strings.TrimSpace(p), binDir) {
			return nil, nil
		}
	}

	newPath := current
	if newPath != "" && !strings.HasSuffix(newPath, ";") {
		newPath += ";"
	}
	newPath += binDir

	if err := k.SetStringValue("Path", newPath); err != nil {
		return nil, err
	}
	return []string{"HKCU\\Environment\\Path"}, nil
}

func RemoveFromPath(binDir string) ([]string, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, envRegKey, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return nil, nil
	}
	defer k.Close()

	current, _, err := k.GetStringValue("Path")
	if err != nil {
		return nil, nil
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
		return nil, nil
	}

	if err := k.SetStringValue("Path", strings.Join(kept, ";")); err != nil {
		return nil, err
	}
	return []string{"HKCU\\Environment\\Path"}, nil
}
