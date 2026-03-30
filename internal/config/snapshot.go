package config

import (
	"io"
	"os"
)

// SaveSnapshot copies the current config.env to snapshot path.
// Called after setup/destroy completes successfully.
func SaveSnapshot(configPath, snapshotPath string) error {
	src, err := os.Open(configPath)
	if err != nil {
		return err
	}
	defer src.Close()

	dst, err := os.Create(snapshotPath)
	if err != nil {
		return err
	}
	defer dst.Close()

	_, err = io.Copy(dst, src)
	return err
}

// PendingChanges compares current config against the snapshot.
// Returns a map of key → snapshot value for keys that differ.
// Returns nil if no snapshot exists (treat as all-effective).
func PendingChanges(configPath, snapshotPath string) map[string]string {
	snap, err := ReadEnv(snapshotPath)
	if err != nil {
		return nil
	}
	current, err := ReadEnv(configPath)
	if err != nil {
		return nil
	}

	pending := make(map[string]string)
	allKeys := make(map[string]bool)
	for k := range current {
		allKeys[k] = true
	}
	for k := range snap {
		allKeys[k] = true
	}

	for k := range allKeys {
		cv := current[k]
		sv := snap[k]
		if cv != sv {
			pending[k] = sv
		}
	}
	return pending
}
