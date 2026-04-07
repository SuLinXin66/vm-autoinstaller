package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadEnv(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.env")
	content := `# comment
VM_NAME=my-vm
VM_CPUS=4
NETWORK_MODE="nat"          # nat | bridge
VM_MEMORY=4096              # MB
EMPTY=
QUOTED="hello"
BRIDGE_NAME="br0"           # Only used when NETWORK_MODE=bridge
UNQUOTED_COMMENT=value      # some comment
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	env, err := ReadEnv(path)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		key, want string
	}{
		{"VM_NAME", "my-vm"},
		{"VM_CPUS", "4"},
		{"NETWORK_MODE", "nat"},
		{"VM_MEMORY", "4096"},
		{"EMPTY", ""},
		{"QUOTED", "hello"},
		{"BRIDGE_NAME", "br0"},
		{"UNQUOTED_COMMENT", "value"},
	}
	for _, tt := range tests {
		if got := env[tt.key]; got != tt.want {
			t.Errorf("ReadEnv[%s] = %q, want %q", tt.key, got, tt.want)
		}
	}

	if _, ok := env["comment"]; ok {
		t.Error("comments should be skipped")
	}
}

func TestWriteValue(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.env")
	content := `VM_NAME=old-vm
VM_CPUS=2
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := WriteValue(path, "VM_NAME", "new-vm"); err != nil {
		t.Fatal(err)
	}
	if err := WriteValue(path, "VM_MEMORY", "4096"); err != nil {
		t.Fatal(err)
	}

	env, err := ReadEnv(path)
	if err != nil {
		t.Fatal(err)
	}
	if env["VM_NAME"] != "new-vm" {
		t.Errorf("VM_NAME = %q, want %q", env["VM_NAME"], "new-vm")
	}
	if env["VM_CPUS"] != "2" {
		t.Errorf("VM_CPUS = %q, want %q", env["VM_CPUS"], "2")
	}
	if env["VM_MEMORY"] != "4096" {
		t.Errorf("VM_MEMORY = %q, want %q", env["VM_MEMORY"], "4096")
	}
}

func TestWriteValueNewFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "new.env")

	if err := WriteValue(path, "KEY", "VALUE"); err != nil {
		t.Fatal(err)
	}

	env, err := ReadEnv(path)
	if err != nil {
		t.Fatal(err)
	}
	if env["KEY"] != "VALUE" {
		t.Errorf("KEY = %q, want %q", env["KEY"], "VALUE")
	}
}

func TestValidateValue(t *testing.T) {
	tests := []struct {
		key, val string
		wantErr  bool
	}{
		{"VM_CPUS", "4", false},
		{"VM_CPUS", "0", false},
		{"VM_CPUS", "-1", true},
		{"VM_CPUS", "abc", true},
		{"NETWORK_MODE", "nat", false},
		{"NETWORK_MODE", "bridge", false},
		{"NETWORK_MODE", "invalid", true},
		{"VM_NAME", "anything", false},
		{"UNKNOWN_KEY", "anything", false},
	}
	for _, tt := range tests {
		err := ValidateValue(tt.key, tt.val)
		if (err != nil) != tt.wantErr {
			t.Errorf("ValidateValue(%s, %s) err=%v, wantErr=%v", tt.key, tt.val, err, tt.wantErr)
		}
	}
}
