package share

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
)

type Share struct {
	Name       string    `json:"name"`
	Tag        string    `json:"tag"`
	HostPath   string    `json:"host_path"`
	MountPoint string    `json:"mount_point"`
	Enabled    bool      `json:"enabled"`
	Note       string    `json:"note,omitempty"`
	AddedAt    time.Time `json:"added_at"`
	Builtin    bool      `json:"builtin,omitempty"`
	ReadOnly   bool      `json:"read_only,omitempty"`
}

func Load() ([]Share, error) {
	p := paths.SharesPath()
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var shares []Share
	if err := json.Unmarshal(data, &shares); err != nil {
		return nil, fmt.Errorf("解析 shares.json 失败: %w", err)
	}
	return shares, nil
}

func Save(shares []Share) error {
	p := paths.SharesPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(shares, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o644)
}

func FindByName(shares []Share, name string) (int, *Share) {
	for i := range shares {
		if shares[i].Name == name {
			return i, &shares[i]
		}
	}
	return -1, nil
}

func FindByMapping(shares []Share, hostPath, mountPoint string) (int, *Share) {
	for i := range shares {
		if shares[i].HostPath == hostPath && shares[i].MountPoint == mountPoint {
			return i, &shares[i]
		}
	}
	return -1, nil
}

func FindByTag(shares []Share, tag string) (int, *Share) {
	for i := range shares {
		if shares[i].Tag == tag {
			return i, &shares[i]
		}
	}
	return -1, nil
}

func FindByMountPoint(shares []Share, mountPoint string) (int, *Share) {
	for i := range shares {
		if shares[i].MountPoint == mountPoint {
			return i, &shares[i]
		}
	}
	return -1, nil
}

func GenerateTag(hostPath, mountPoint string) string {
	h := sha256.Sum256([]byte(hostPath + ":" + mountPoint))
	return fmt.Sprintf("s-%x", h[:5])
}

func DefaultMountPoint(tag string) string {
	return "/mnt/shares/" + tag
}

func DefaultName(hostPath string) string {
	return filepath.Base(hostPath)
}
