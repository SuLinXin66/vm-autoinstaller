package config

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

type Level int

const (
	LevelRestart Level = iota
	LevelRebuild
	LevelNone
)

func (l Level) String() string {
	switch l {
	case LevelRestart:
		return "需重启 VM"
	case LevelRebuild:
		return "需重建 VM"
	default:
		return ""
	}
}

type ValueType int

const (
	TypeString ValueType = iota
	TypeInt
	TypeEnum
)

type KeyMeta struct {
	Description  string
	EffectLevel  Level
	Type         ValueType
	EnumValues   []string
	DefaultValue string
}

var KnownKeys = map[string]KeyMeta{
	"VM_NAME":        {Description: "VM 名称", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: "ubuntu-server"},
	"VM_CPUS":        {Description: "CPU 核数", EffectLevel: LevelRestart, Type: TypeInt, DefaultValue: "2"},
	"VM_MEMORY":      {Description: "内存 (MB)", EffectLevel: LevelRestart, Type: TypeInt, DefaultValue: "2048"},
	"VM_DISK_SIZE":   {Description: "磁盘大小 (GB)", EffectLevel: LevelRebuild, Type: TypeInt, DefaultValue: "20"},
	"VM_USER":        {Description: "登录用户名", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: "wpsweb"},
	"UBUNTU_VERSION": {Description: "Ubuntu 版本", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: "24.04"},
	"NETWORK_MODE":   {Description: "网络模式", EffectLevel: LevelRebuild, Type: TypeEnum, EnumValues: []string{"nat", "bridge"}, DefaultValue: "nat"},
	"DATA_DIR":       {Description: "镜像和磁盘存储目录", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: "~/.kvm-ubuntu"},
}

func ValidateValue(key, value string) error {
	m, ok := KnownKeys[key]
	if !ok {
		return nil
	}
	switch m.Type {
	case TypeInt:
		n, err := strconv.Atoi(value)
		if err != nil || n <= 0 {
			return fmt.Errorf("键 %s 的值必须为正整数，当前: %s", key, value)
		}
	case TypeEnum:
		found := false
		for _, v := range m.EnumValues {
			if v == value {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("键 %s 仅允许: %s，当前: %s", key, strings.Join(m.EnumValues, "/"), value)
		}
	}
	return nil
}

func ReadEnv(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	result := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		val = parseValue(val)
		val = expandShellVars(val)
		result[key] = val
	}
	return result, scanner.Err()
}

func WriteValue(path, key, value string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return os.WriteFile(path, []byte(key+"="+value+"\n"), 0o644)
		}
		return err
	}

	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		idx := strings.IndexByte(trimmed, '=')
		if idx < 0 {
			continue
		}
		k := strings.TrimSpace(trimmed[:idx])
		if k == key {
			lines[i] = key + "=" + value
			found = true
			break
		}
	}

	if !found {
		lines = append(lines, key+"="+value)
	}

	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o644)
}

func expandShellVars(val string) string {
	return os.Expand(val, func(key string) string {
		if v := os.Getenv(key); v != "" {
			return v
		}
		if key == "HOME" || key == "USERPROFILE" {
			home, _ := os.UserHomeDir()
			return home
		}
		return ""
	})
}

func parseValue(raw string) string {
	// Quoted value: extract content between matching quotes, ignore rest
	if len(raw) >= 2 {
		q := raw[0]
		if q == '"' || q == '\'' {
			if end := strings.IndexByte(raw[1:], q); end >= 0 {
				return raw[1 : end+1]
			}
		}
	}
	// Unquoted: strip inline comment (# preceded by whitespace)
	if idx := strings.Index(raw, " #"); idx >= 0 {
		return strings.TrimRight(raw[:idx], " \t")
	}
	if idx := strings.Index(raw, "\t#"); idx >= 0 {
		return strings.TrimRight(raw[:idx], " \t")
	}
	return raw
}

func SortedKeys[M ~map[string]V, V any](m M) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
