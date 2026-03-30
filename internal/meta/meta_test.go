package meta

import (
	"path/filepath"
	"testing"
)

func TestSaveAndLoad(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".install-meta.json")

	m := &InstallMeta{
		AppName:       "test-app",
		CLIVersion:    "v1.0.0",
		BundleVersion: "v1.0.0",
		RepoURL:       "https://github.com/test/repo",
		Branch:        "main",
		PathEntries:   []string{"/home/user/.bashrc"},
	}

	if err := m.Save(path); err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}

	if loaded.AppName != m.AppName {
		t.Errorf("AppName = %q, want %q", loaded.AppName, m.AppName)
	}
	if loaded.CLIVersion != m.CLIVersion {
		t.Errorf("CLIVersion = %q, want %q", loaded.CLIVersion, m.CLIVersion)
	}
	if loaded.RepoURL != m.RepoURL {
		t.Errorf("RepoURL = %q, want %q", loaded.RepoURL, m.RepoURL)
	}
	if loaded.Branch != m.Branch {
		t.Errorf("Branch = %q, want %q", loaded.Branch, m.Branch)
	}
	if len(loaded.PathEntries) != 1 || loaded.PathEntries[0] != "/home/user/.bashrc" {
		t.Errorf("PathEntries = %v, want %v", loaded.PathEntries, m.PathEntries)
	}
}

func TestLoadNonExistent(t *testing.T) {
	_, err := Load("/nonexistent/path.json")
	if err == nil {
		t.Error("expected error for non-existent file")
	}
}
