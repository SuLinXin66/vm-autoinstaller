package share

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// BuiltinDef represents a single builtin share definition parsed from the
// build-time DEFAULT_BUILTIN_SHARES string.
type BuiltinDef struct {
	HostPath   string
	MountPoint string
	ReadOnly   bool
}

// ParseBuiltinShares parses "~/.ssh:~/.ssh:ro,~/works:/mnt/works" into a
// slice of BuiltinDef with host-side ~ expanded.
func ParseBuiltinShares(raw string) []BuiltinDef {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	home, _ := os.UserHomeDir()
	expandHost := func(p string) string {
		if strings.HasPrefix(p, "~/") {
			return home + p[1:]
		}
		if p == "~" {
			return home
		}
		return p
	}

	var defs []BuiltinDef
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, ":", 3)
		if len(parts) < 2 {
			continue
		}
		d := BuiltinDef{
			HostPath:   expandHost(parts[0]),
			MountPoint: parts[1], // VM-side ~ is kept literal, resolved at mount time
			ReadOnly:   len(parts) >= 3 && parts[2] == "ro",
		}
		defs = append(defs, d)
	}
	return defs
}

// ExpandVMMountPoint resolves ~ in the VM mount point to the VM user's home.
func ExpandVMMountPoint(mp, vmUser string) string {
	vmHome := "/home/" + vmUser
	if strings.HasPrefix(mp, "~/") {
		return vmHome + mp[1:]
	}
	if mp == "~" {
		return vmHome
	}
	return mp
}

// ReconcileResult holds information about what reconciliation did.
type ReconcileResult struct {
	Added    []string
	Updated  []string
	Removed  []string
	Restored []string
	// Conflicts lists user shares that conflict with builtin definitions.
	Conflicts []string
}

func (r ReconcileResult) HasChanges() bool {
	return len(r.Added) > 0 || len(r.Updated) > 0 || len(r.Removed) > 0 || len(r.Restored) > 0
}

// ReconcileBuiltinShares performs the full reconciliation of builtin shares.
// vmUser is used to expand ~ in VM mount points.
// If stopOnConflict is true, conflicts cause an error return (installer mode).
func ReconcileBuiltinShares(raw, vmUser string, stopOnConflict bool) (*ReconcileResult, error) {
	defs := ParseBuiltinShares(raw)
	current, _ := Load()
	if current == nil {
		current = []Share{}
	}

	result := &ReconcileResult{}

	// Expand VM-side ~ for all defs
	for i := range defs {
		defs[i].MountPoint = ExpandVMMountPoint(defs[i].MountPoint, vmUser)
	}

	// Conflict detection: user shares vs builtin definitions
	for _, d := range defs {
		for _, s := range current {
			if s.Builtin {
				continue
			}
			// Same mount point but different host path
			if s.MountPoint == d.MountPoint && s.HostPath != d.HostPath {
				msg := fmt.Sprintf("用户共享 [%s] 与内置共享冲突（挂载点: %s），请先执行 share rm %s",
					s.Name, d.MountPoint, s.Name)
				result.Conflicts = append(result.Conflicts, msg)
			}
			// Same host path + mount point (user share duplicates builtin)
			if s.HostPath == d.HostPath && s.MountPoint == d.MountPoint {
				msg := fmt.Sprintf("用户共享 [%s] 与内置共享冲突（%s → %s），请先执行 share rm %s",
					s.Name, d.HostPath, d.MountPoint, s.Name)
				result.Conflicts = append(result.Conflicts, msg)
			}
		}
	}

	if len(result.Conflicts) > 0 && stopOnConflict {
		return result, fmt.Errorf("内置共享目录冲突:\n  %s", strings.Join(result.Conflicts, "\n  "))
	}

	changed := false

	// ADD + UPDATE + RESTORE
	for _, d := range defs {
		idx, existing := FindByMapping(current, d.HostPath, d.MountPoint)
		if existing == nil {
			tag := GenerateTag(d.HostPath, d.MountPoint)
			name := DefaultName(d.HostPath)
			s := Share{
				Name:       name,
				Tag:        tag,
				HostPath:   d.HostPath,
				MountPoint: d.MountPoint,
				Enabled:    true,
				Builtin:    true,
				ReadOnly:   d.ReadOnly,
				AddedAt:    time.Now(),
			}
			current = append(current, s)
			result.Added = append(result.Added, fmt.Sprintf("%s → %s", d.HostPath, d.MountPoint))
			changed = true
		} else {
			needUpdate := false

			if !existing.Builtin {
				existing.Builtin = true
				needUpdate = true
			}
			if !existing.Enabled {
				existing.Enabled = true
				needUpdate = true
				result.Restored = append(result.Restored, existing.Name)
			}
			if existing.ReadOnly != d.ReadOnly {
				existing.ReadOnly = d.ReadOnly
				needUpdate = true
			}

			if needUpdate {
				current[idx] = *existing
				if len(result.Restored) == 0 || result.Restored[len(result.Restored)-1] != existing.Name {
					result.Updated = append(result.Updated, existing.Name)
				}
				changed = true
			}
		}
	}

	// REMOVE: builtin entries not in current desired set
	for i := len(current) - 1; i >= 0; i-- {
		if !current[i].Builtin {
			continue
		}
		found := false
		for _, d := range defs {
			if current[i].HostPath == d.HostPath && current[i].MountPoint == d.MountPoint {
				found = true
				break
			}
		}
		if !found {
			result.Removed = append(result.Removed, current[i].Name)
			current = append(current[:i], current[i+1:]...)
			changed = true
		}
	}

	if changed {
		if err := Save(current); err != nil {
			return result, fmt.Errorf("保存 shares.json 失败: %w", err)
		}
	}

	return result, nil
}

// CheckBuiltinAlignment checks if all builtin shares are properly present and
// enabled in shares.json. Returns a list of warning messages (empty = aligned).
func CheckBuiltinAlignment(raw, vmUser string) []string {
	defs := ParseBuiltinShares(raw)
	if len(defs) == 0 {
		return nil
	}

	for i := range defs {
		defs[i].MountPoint = ExpandVMMountPoint(defs[i].MountPoint, vmUser)
	}

	current, _ := Load()
	if current == nil {
		current = []Share{}
	}

	var warnings []string

	for _, d := range defs {
		_, existing := FindByMapping(current, d.HostPath, d.MountPoint)
		if existing == nil {
			roStr := ""
			if d.ReadOnly {
				roStr = " (只读)"
			}
			warnings = append(warnings, fmt.Sprintf("缺少内置共享目录: %s → %s%s", d.HostPath, d.MountPoint, roStr))
			continue
		}
		if !existing.Builtin {
			warnings = append(warnings, fmt.Sprintf("内置共享 [%s] 的 Builtin 标记被篡改", existing.Name))
		}
		if !existing.Enabled {
			warnings = append(warnings, fmt.Sprintf("内置共享 [%s] 被禁用", existing.Name))
		}
		if existing.ReadOnly != d.ReadOnly {
			warnings = append(warnings, fmt.Sprintf("内置共享 [%s] 的只读属性不一致", existing.Name))
		}
	}

	// Check for stale builtin entries
	for _, s := range current {
		if !s.Builtin {
			continue
		}
		found := false
		for _, d := range defs {
			if s.HostPath == d.HostPath && s.MountPoint == d.MountPoint {
				found = true
				break
			}
		}
		if !found {
			warnings = append(warnings, fmt.Sprintf("残留的旧版内置共享 [%s] 需要清理", s.Name))
		}
	}

	return warnings
}
