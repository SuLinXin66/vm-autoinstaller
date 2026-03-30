//go:build !windows

package pathmgr

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMarkerBlockContainsCompletion(t *testing.T) {
	block := markerBlock("/home/test/.local/share/kvm-ubuntu/bin", "zsh")
	if !strings.Contains(block, "completion zsh") {
		t.Errorf("zsh marker block missing completion line:\n%s", block)
	}
	if !strings.Contains(block, "export PATH=") {
		t.Errorf("marker block missing PATH export:\n%s", block)
	}

	block = markerBlock("/home/test/.local/share/kvm-ubuntu/bin", "bash")
	if !strings.Contains(block, "completion bash") {
		t.Errorf("bash marker block missing completion line:\n%s", block)
	}

	block = markerBlock("/home/test/.local/share/kvm-ubuntu/bin", "")
	if strings.Contains(block, "completion") {
		t.Errorf("profile marker block should NOT contain completion:\n%s", block)
	}

	t.Logf("zsh block:\n%s", markerBlock("/home/user/.local/share/kvm-ubuntu/bin", "zsh"))
}

func TestAddAndRemovePath(t *testing.T) {
	dir := t.TempDir()

	zshrc := filepath.Join(dir, ".zshrc")
	bashrc := filepath.Join(dir, ".bashrc")
	os.WriteFile(zshrc, []byte("# existing content\n"), 0o644)
	os.WriteFile(bashrc, []byte("# existing content\n"), 0o644)

	origHome := os.Getenv("HOME")
	os.Setenv("HOME", dir)
	defer os.Setenv("HOME", origHome)

	binDir := filepath.Join(dir, "bin")
	modified, err := AddToPath(binDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(modified) != 2 {
		t.Fatalf("expected 2 modified files, got %d: %v", len(modified), modified)
	}

	data, _ := os.ReadFile(zshrc)
	content := string(data)
	if !strings.Contains(content, "completion zsh") {
		t.Errorf(".zshrc missing zsh completion:\n%s", content)
	}
	if !strings.Contains(content, "export PATH=") {
		t.Errorf(".zshrc missing PATH:\n%s", content)
	}

	data, _ = os.ReadFile(bashrc)
	content = string(data)
	if !strings.Contains(content, "completion bash") {
		t.Errorf(".bashrc missing bash completion:\n%s", content)
	}

	// Idempotent: run again, should still work (rewrites block)
	modified2, err := AddToPath(binDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(modified2) != 2 {
		t.Fatalf("expected 2 modified on re-run, got %d", len(modified2))
	}

	// Remove
	removed, err := RemoveFromPath(binDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 2 {
		t.Fatalf("expected 2 removed, got %d", len(removed))
	}

	data, _ = os.ReadFile(zshrc)
	content = string(data)
	if strings.Contains(content, "completion") {
		t.Errorf(".zshrc still contains completion after removal:\n%s", content)
	}
	if strings.Contains(content, "export PATH=") {
		t.Errorf(".zshrc still contains PATH after removal:\n%s", content)
	}
}
