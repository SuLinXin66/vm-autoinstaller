package main

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gookit/color"
	"github.com/jedib0t/go-pretty/v6/table"
	"github.com/spf13/cobra"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/config"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
)

type mirrorDef struct {
	Name      string
	Label     string
	UbuntuURL string
	DockerURL string
}

var knownMirrors = []mirrorDef{
	{"ustc", "中科大 (USTC)", "https://mirrors.ustc.edu.cn/ubuntu/", "https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu"},
	{"tsinghua", "清华 (TUNA)", "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/", "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu"},
	{"aliyun", "阿里云", "https://mirrors.aliyun.com/ubuntu/", "https://mirrors.aliyun.com/docker-ce/linux/ubuntu"},
	{"huawei", "华为云", "https://repo.huaweicloud.com/ubuntu/", "https://repo.huaweicloud.com/docker-ce/linux/ubuntu"},
}

const (
	officialUbuntuURL = "http://archive.ubuntu.com/ubuntu/"
	officialSecURL    = "http://security.ubuntu.com/ubuntu/"
	officialDockerURL = "https://download.docker.com/linux/ubuntu"
)

func findMirror(name string) *mirrorDef {
	lower := strings.ToLower(name)
	for i := range knownMirrors {
		if knownMirrors[i].Name == lower {
			return &knownMirrors[i]
		}
	}
	return nil
}

func resolveMirrorURLs(input string) (ubuntuURL, dockerURL, display string) {
	if m := findMirror(input); m != nil {
		return m.UbuntuURL, m.DockerURL, m.Name + " (" + m.Label + ")"
	}
	url := strings.TrimRight(input, "/") + "/"
	return url, "", input
}

func newMirrorCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "mirror",
		Short: "查看/管理 VM APT 镜像源",
		RunE: func(cmd *cobra.Command, args []string) error {
			return showMirror()
		},
	}

	setCmd := &cobra.Command{
		Use:   "set <名称|URL>",
		Short: "设置 APT 镜像源（ustc/tsinghua/aliyun/huawei 或自定义 URL）",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return setMirror(args[0])
		},
	}

	unsetCmd := &cobra.Command{
		Use:   "unset",
		Short: "恢复为官方源",
		RunE: func(cmd *cobra.Command, args []string) error {
			return unsetMirror()
		},
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "列出可用的预置镜像源",
		RunE: func(cmd *cobra.Command, args []string) error {
			return listMirrors()
		},
	}

	cmd.AddCommand(setCmd, unsetCmd, listCmd)
	return cmd
}

func setMirror(input string) error {
	if !strings.HasPrefix(input, "http://") && !strings.HasPrefix(input, "https://") {
		if findMirror(input) == nil {
			return fmt.Errorf("未知的镜像名 %q，使用 %s mirror list 查看可用镜像", input, buildinfo.AppName)
		}
	}

	cfgPath := paths.ConfigEnvPath()
	if err := config.WriteValue(cfgPath, "APT_MIRROR", input); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}

	_, _, display := resolveMirrorURLs(input)
	color.Green.Printf("✓ 镜像源已保存: %s\n", display)

	cfg, err := loadConfig()
	if err != nil {
		fmt.Printf("提示: VM 尚未安装，镜像源将在 %s setup 后自动生效。\n", buildinfo.AppName)
		return nil
	}

	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		fmt.Println("提示: VM 未运行，镜像源将在下次启动后自动生效。")
		return nil
	}

	ubuntuURL, dockerURL, _ := resolveMirrorURLs(input)
	if err := applyMirrorToVM(cfg, ubuntuURL, dockerURL); err != nil {
		return fmt.Errorf("应用镜像源到 VM 失败: %w", err)
	}
	color.Green.Println("✓ 镜像源已应用到 VM（Ubuntu + Docker）")
	return nil
}

func unsetMirror() error {
	cfgPath := paths.ConfigEnvPath()
	if err := config.WriteValue(cfgPath, "APT_MIRROR", ""); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	color.Green.Println("✓ 镜像源已恢复为官方源")

	cfg, err := loadConfig()
	if err != nil {
		return nil
	}

	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		fmt.Println("提示: VM 未运行，变更将在下次启动后生效。")
		return nil
	}

	if err := restoreMirrorOnVM(cfg); err != nil {
		return fmt.Errorf("恢复 VM 官方源失败: %w", err)
	}
	color.Green.Println("✓ VM 已恢复官方源")
	return nil
}

func showMirror() error {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Println("尚未安装，无镜像源配置。")
		return nil
	}

	mirror := cfgValCN(cfg, "APT_MIRROR")
	if mirror == "" {
		fmt.Println("当前使用官方源。")
		fmt.Printf("使用 %s mirror set <名称|URL> 设置国内镜像源。\n", buildinfo.AppName)
		fmt.Printf("使用 %s mirror list 查看可用预置镜像。\n", buildinfo.AppName)
		return nil
	}

	_, _, display := resolveMirrorURLs(mirror)
	fmt.Printf("本地配置: %s\n", color.Green.Sprint(display))

	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		fmt.Println("VM 未运行，无法查询 VM 内镜像状态。")
		return nil
	}

	out, err := sshExec(cfg, "grep -m1 'URIs:' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | awk '{print $2}'")
	if err == nil && strings.TrimSpace(out) != "" {
		vmMirror := strings.TrimSpace(out)
		if vmMirror == officialUbuntuURL || vmMirror == "http://archive.ubuntu.com/ubuntu" {
			color.Yellow.Println("VM 内仍为官方源，请执行 setup 或 restart 应用。")
		} else {
			fmt.Printf("VM 生效中:  %s\n", color.Green.Sprint(vmMirror))
		}
	}
	return nil
}

func listMirrors() error {
	t := table.NewWriter()
	t.SetStyle(table.StyleRounded)
	t.AppendHeader(table.Row{"名称", "提供方", "Ubuntu 镜像", "Docker CE 镜像"})
	for _, m := range knownMirrors {
		t.AppendRow(table.Row{m.Name, m.Label, m.UbuntuURL, m.DockerURL})
	}
	fmt.Println(t.Render())
	fmt.Printf("\n使用方法: %s mirror set <名称>\n", buildinfo.AppName)
	fmt.Printf("示例:     %s mirror set ustc\n", buildinfo.AppName)
	return nil
}

func applyMirrorToVM(cfg map[string]string, ubuntuURL, dockerURL string) error {
	cmds := []string{
		fmt.Sprintf(
			`sudo sed -i 's|http://archive.ubuntu.com/ubuntu/\?|%s|g; s|http://security.ubuntu.com/ubuntu/\?|%s|g' /etc/apt/sources.list.d/ubuntu.sources`,
			ubuntuURL, ubuntuURL),
	}
	if dockerURL != "" {
		cmds = append(cmds, fmt.Sprintf(
			`sudo sed -i 's|https://download.docker.com/linux/ubuntu|%s|g' /etc/apt/sources.list.d/docker.list 2>/dev/null || true`,
			dockerURL))
	}
	cmds = append(cmds, "sudo apt-get update -qq")
	_, err := sshExec(cfg, strings.Join(cmds, " && "))
	return err
}

func restoreMirrorOnVM(cfg map[string]string) error {
	cmds := []string{
		fmt.Sprintf(
			`sudo sed -i 's|https\?://[^/]*/ubuntu/\?|%s|g' /etc/apt/sources.list.d/ubuntu.sources`,
			officialUbuntuURL),
		fmt.Sprintf(
			`sudo sed -i 's|https\?://[^/]*/docker-ce/linux/ubuntu|%s|g' /etc/apt/sources.list.d/docker.list 2>/dev/null || true`,
			officialDockerURL),
		"sudo apt-get update -qq",
	}
	_, err := sshExec(cfg, strings.Join(cmds, " && "))
	return err
}

// --- Mirror auto-selection ---

var versionCodenames = map[string]string{
	"20.04": "focal",
	"22.04": "jammy",
	"24.04": "noble",
	"24.10": "oracular",
	"25.04": "plucky",
}

func resolveUbuntuCodename() string {
	version := buildinfo.DefaultUbuntuVersion
	cfg, err := config.ReadEnv(paths.ConfigEnvPath())
	if err == nil {
		if v, ok := cfg["UBUNTU_VERSION"]; ok && v != "" {
			version = v
		}
	}
	if c, ok := versionCodenames[version]; ok {
		return c
	}
	return "noble"
}

func testURL(url string) bool {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Head(url)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode < 400
}

var (
	cachedBestMirror string
	mirrorTestOnce   sync.Once
)

func selectBestMirror() string {
	mirrorTestOnce.Do(func() {
		cachedBestMirror = doSelectBestMirror()
	})
	return cachedBestMirror
}

func doSelectBestMirror() string {
	codename := resolveUbuntuCodename()

	type testResult struct {
		idx     int
		ubuntu  bool
		docker  bool
		latency time.Duration
	}

	results := make([]testResult, len(knownMirrors))
	var wg sync.WaitGroup

	fmt.Print("测试镜像源可用性... ")

	for i, m := range knownMirrors {
		wg.Add(1)
		go func(idx int, m mirrorDef) {
			defer wg.Done()
			start := time.Now()

			var ubuntuOK, dockerOK bool
			var inner sync.WaitGroup

			inner.Add(1)
			go func() {
				defer inner.Done()
				ubuntuOK = testURL(m.UbuntuURL + "dists/" + codename + "/InRelease")
			}()

			inner.Add(1)
			go func() {
				defer inner.Done()
				if m.DockerURL == "" {
					dockerOK = true
					return
				}
				dockerOK = testURL(m.DockerURL + "/dists/" + codename + "/InRelease")
			}()

			inner.Wait()

			results[idx] = testResult{
				idx:     idx,
				ubuntu:  ubuntuOK,
				docker:  dockerOK,
				latency: time.Since(start),
			}
		}(i, m)
	}

	wg.Wait()

	// Tier 1: both Ubuntu and Docker CE work, pick fastest
	bestIdx := -1
	for _, r := range results {
		if r.ubuntu && r.docker {
			if bestIdx == -1 || r.latency < results[bestIdx].latency {
				bestIdx = r.idx
			}
		}
	}
	if bestIdx >= 0 {
		m := knownMirrors[bestIdx]
		fmt.Printf("%s (%dms)\n", color.Green.Sprint(m.Label), results[bestIdx].latency.Milliseconds())
		return m.Name
	}

	// Tier 2: only Ubuntu works (Docker CE mirror out of sync, tolerable)
	for _, r := range results {
		if r.ubuntu {
			if bestIdx == -1 || r.latency < results[bestIdx].latency {
				bestIdx = r.idx
			}
		}
	}
	if bestIdx >= 0 {
		m := knownMirrors[bestIdx]
		color.Yellow.Printf("%s (%dms, Docker CE 镜像不可用)\n", m.Label, results[bestIdx].latency.Milliseconds())
		return m.Name
	}

	color.Yellow.Println("所有镜像不可达，使用默认 (ustc)")
	return "ustc"
}

func ensureMirror() {
	cfg, err := loadConfig()
	if err != nil {
		return
	}
	mirror := cfgValCN(cfg, "APT_MIRROR")
	if mirror == "" {
		return
	}
	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		return
	}
	ubuntuURL, _, display := resolveMirrorURLs(mirror)

	out, err := sshExec(cfg, "cat /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null")
	if err == nil && strings.Contains(out, strings.TrimRight(ubuntuURL, "/")) {
		fmt.Printf("镜像源: %s\n", color.Green.Sprint(display))
		return
	}

	// SSH 失败或源文件不存在时也跳过，不要在每次 setup 时触发 apt-get update
	if err != nil {
		return
	}

	_, dockerURL, _ := resolveMirrorURLs(mirror)
	if err := applyMirrorToVM(cfg, ubuntuURL, dockerURL); err != nil {
		color.Yellow.Printf("⚠ 镜像源应用失败: %v\n", err)
	} else {
		fmt.Printf("镜像源: %s (已应用)\n", color.Green.Sprint(display))
	}
}
