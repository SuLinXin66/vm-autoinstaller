package main

import (
	"fmt"
	"strings"

	"github.com/gookit/color"
	"github.com/spf13/cobra"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
	"github.com/SuLinXin66/vm-autoinstaller/internal/config"
	"github.com/SuLinXin66/vm-autoinstaller/internal/paths"
)

func newProxyCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "proxy",
		Short: "查看/管理 VM 代理设置",
		RunE: func(cmd *cobra.Command, args []string) error {
			return showProxy()
		},
	}

	setCmd := &cobra.Command{
		Use:   "set <proxy_url>",
		Short: "设置代理（如 http://192.168.1.1:7890）",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return setProxy(args[0])
		},
	}

	unsetCmd := &cobra.Command{
		Use:   "unset",
		Short: "移除代理设置",
		RunE: func(cmd *cobra.Command, args []string) error {
			return unsetProxy()
		},
	}

	cmd.AddCommand(setCmd, unsetCmd)
	return cmd
}

func setProxy(proxyURL string) error {
	if !strings.HasPrefix(proxyURL, "http://") && !strings.HasPrefix(proxyURL, "https://") &&
		!strings.HasPrefix(proxyURL, "socks5://") {
		return fmt.Errorf("代理地址格式不正确，需要以 http:// / https:// / socks5:// 开头")
	}

	cfgPath := paths.ConfigEnvPath()
	if err := config.WriteValue(cfgPath, "PROXY", proxyURL); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	color.Green.Printf("✓ 代理已保存: %s\n", proxyURL)

	cfg, err := loadConfig()
	if err != nil {
		fmt.Printf("提示: VM 尚未安装，代理将在 %s setup 后自动生效。\n", buildinfo.AppName)
		return nil
	}

	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		fmt.Println("提示: VM 未运行，代理将在下次启动后自动生效。")
		return nil
	}

	if err := applyProxyToVM(cfg, proxyURL); err != nil {
		return fmt.Errorf("应用代理到 VM 失败: %w", err)
	}
	color.Green.Println("✓ 代理已应用到 VM（apt + 环境变量）")
	return nil
}

func unsetProxy() error {
	cfgPath := paths.ConfigEnvPath()
	if err := config.WriteValue(cfgPath, "PROXY", ""); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	color.Green.Println("✓ 代理配置已移除")

	cfg, err := loadConfig()
	if err != nil {
		return nil
	}

	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		fmt.Println("提示: VM 未运行，变更将在下次启动后生效。")
		return nil
	}

	if err := removeProxyFromVM(cfg); err != nil {
		return fmt.Errorf("清除 VM 代理失败: %w", err)
	}
	color.Green.Println("✓ VM 代理已清除")
	return nil
}

func showProxy() error {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Println("尚未安装，无代理配置。")
		return nil
	}

	proxyURL := cfgVal(cfg, "PROXY")
	if proxyURL == "" {
		fmt.Println("当前未设置代理。")
		fmt.Printf("使用 %s proxy set <url> 设置代理。\n", buildinfo.AppName)
		return nil
	}

	fmt.Printf("本地配置: %s\n", color.Green.Sprint(proxyURL))

	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		fmt.Println("VM 未运行，无法查询 VM 内代理状态。")
		return nil
	}

	out, err := sshExec(cfg, "echo $http_proxy")
	if err == nil && strings.TrimSpace(out) != "" {
		fmt.Printf("VM 生效中:  %s\n", color.Green.Sprint(strings.TrimSpace(out)))
	} else {
		color.Yellow.Println("VM 内代理未生效，请执行 setup 或 restart 应用。")
	}
	return nil
}

// applyProxyToVM sets proxy in VM's apt config and environment.
func applyProxyToVM(cfg map[string]string, proxyURL string) error {
	aptConf := fmt.Sprintf(
		`Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";`,
		proxyURL, proxyURL)
	aptCmd := fmt.Sprintf("echo -e '%s' | sudo tee /etc/apt/apt.conf.d/99proxy > /dev/null", aptConf)

	envLines := fmt.Sprintf(
		`http_proxy=%s\nhttps_proxy=%s\nHTTP_PROXY=%s\nHTTPS_PROXY=%s\nno_proxy=localhost,127.0.0.1,::1`,
		proxyURL, proxyURL, proxyURL, proxyURL)
	envCmd := fmt.Sprintf("echo -e '%s' | sudo tee /etc/profile.d/proxy.sh > /dev/null && sudo chmod +x /etc/profile.d/proxy.sh", envLines)

	// Also write to /etc/environment for non-login processes
	envFileCmd := fmt.Sprintf(
		"sudo sed -i '/^http_proxy=/d;/^https_proxy=/d;/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^no_proxy=/d' /etc/environment 2>/dev/null;"+
			" echo -e '%s' | sudo tee -a /etc/environment > /dev/null", envLines)

	combined := aptCmd + " && " + envCmd + " && " + envFileCmd
	_, err := sshExec(cfg, combined)
	return err
}

// removeProxyFromVM removes proxy settings from VM.
func removeProxyFromVM(cfg map[string]string) error {
	cmd := "sudo rm -f /etc/apt/apt.conf.d/99proxy /etc/profile.d/proxy.sh && " +
		"sudo sed -i '/^http_proxy=/d;/^https_proxy=/d;/^HTTP_PROXY=/d;/^HTTPS_PROXY=/d;/^no_proxy=/d' /etc/environment 2>/dev/null"
	_, err := sshExec(cfg, cmd)
	return err
}

// ensureProxy applies proxy to VM if configured. Called after setup/restart.
func ensureProxy() {
	cfg, err := loadConfig()
	if err != nil {
		return
	}
	proxyURL := cfgVal(cfg, "PROXY")
	if proxyURL == "" {
		return
	}
	vmName := cfgVal(cfg, "VM_NAME")
	if !isVMRunning(cfg, vmName) {
		return
	}
	if err := applyProxyToVM(cfg, proxyURL); err != nil {
		color.Yellow.Printf("⚠ 代理应用失败: %v\n", err)
	} else {
		fmt.Printf("代理: %s\n", color.Green.Sprint(proxyURL))
	}
}
