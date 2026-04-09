package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
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
	"VM_NAME":                {Description: "VM 名称", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: buildinfo.DefaultVMName},
	"VM_CPUS":                {Description: "CPU 核数 (0=自动)", EffectLevel: LevelRestart, Type: TypeInt, DefaultValue: buildinfo.DefaultVMCPUs},
	"VM_MEMORY":              {Description: "内存 (MB)", EffectLevel: LevelRestart, Type: TypeInt, DefaultValue: buildinfo.DefaultVMMemory},
	"VM_DISK_SIZE":           {Description: "磁盘大小 (GB)", EffectLevel: LevelRebuild, Type: TypeInt, DefaultValue: buildinfo.DefaultVMDiskSize},
	"VM_USER":                {Description: "登录用户名", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: buildinfo.DefaultVMUser},
	"UBUNTU_VERSION":         {Description: "Ubuntu 版本", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: buildinfo.DefaultUbuntuVersion},
	"NETWORK_MODE":           {Description: "网络模式", EffectLevel: LevelRebuild, Type: TypeEnum, EnumValues: []string{"nat", "bridge"}, DefaultValue: buildinfo.DefaultNetworkMode},
	"BRIDGE_NAME":            {Description: "桥接网卡名", EffectLevel: LevelRebuild, Type: TypeString, DefaultValue: buildinfo.DefaultBridgeName},
	"DATA_DIR":               {Description: "镜像和磁盘存储目录", EffectLevel: LevelRebuild, Type: TypeString},
	"UBUNTU_IMAGE_BASE_URL":  {Description: "Cloud Image 下载源", EffectLevel: LevelNone, Type: TypeString, DefaultValue: buildinfo.DefaultUbuntuImageBaseURL},
	"AUTO_YES":               {Description: "跳过确认提示", EffectLevel: LevelNone, Type: TypeEnum, EnumValues: []string{"0", "1"}, DefaultValue: buildinfo.DefaultAutoYes},
	"ENFORCE_RESOURCE_LIMIT": {Description: "强制资源下限", EffectLevel: LevelNone, Type: TypeEnum, EnumValues: []string{"0", "1"}, DefaultValue: buildinfo.DefaultEnforceResourceLimit},
	"PROXY":                  {Description: "VM 代理地址 (如 http://host:port)", EffectLevel: LevelNone, Type: TypeString},
	"APT_MIRROR":             {Description: "APT 镜像源 (ustc/tsinghua/aliyun/huawei 或 URL)", EffectLevel: LevelNone, Type: TypeString, DefaultValue: buildinfo.DefaultAPTMirror},
	"CN_MODE":                {Description: "国内模式 (1=自动使用国内镜像/加速站)", EffectLevel: LevelNone, Type: TypeEnum, EnumValues: []string{"0", "1"}, DefaultValue: buildinfo.DefaultCNMode},
	"GITHUB_PROXY":           {Description: "GitHub 加速前缀 (如 https://ghfast.top/)", EffectLevel: LevelNone, Type: TypeString, DefaultValue: buildinfo.DefaultGitHubProxy},
	"SSH_FORWARD":            {Description: "SSH 密钥/配置映射到 VM", EffectLevel: LevelRestart, Type: TypeEnum, EnumValues: []string{"0", "1"}, DefaultValue: buildinfo.DefaultSSHForward},
}

func init() {
	k := KnownKeys["DATA_DIR"]
	home, _ := os.UserHomeDir()
	k.DefaultValue = filepath.Join(home, "."+buildinfo.AppName)
	KnownKeys["DATA_DIR"] = k
}

func ValidateValue(key, value string) error {
	m, ok := KnownKeys[key]
	if !ok {
		return nil
	}
	switch m.Type {
	case TypeInt:
		n, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("键 %s 的值必须为整数，当前: %s", key, value)
		}
		if key == "VM_CPUS" {
			if n < 0 {
				return fmt.Errorf("键 %s 的值必须 >= 0（0=自动），当前: %s", key, value)
			}
		} else if n <= 0 {
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
