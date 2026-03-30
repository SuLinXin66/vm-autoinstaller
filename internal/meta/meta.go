package meta

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type InstallMeta struct {
	AppName       string   `json:"appName"`
	CLIVersion    string   `json:"cliVersion"`
	BundleVersion string   `json:"bundleVersion"`
	RepoURL       string   `json:"repoURL"`
	Branch        string   `json:"branch"`
	PathEntries   []string `json:"pathEntries"`
}

func Load(path string) (*InstallMeta, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m InstallMeta
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

func (m *InstallMeta) Save(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
