//go:build windows

package winsvc

import (
	"fmt"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
)

// ServiceName returns the Windows service name derived from AppName.
func ServiceName() string {
	return buildinfo.AppName + "-svc"
}

// PipePath returns the Named Pipe path.
func PipePath() string {
	return `\\.\pipe\` + buildinfo.AppName
}

// IsInstalled checks whether the service is registered with SCM.
// Uses SERVICE_QUERY_STATUS so it works without admin privileges.
func IsInstalled() bool {
	h, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return false
	}
	defer windows.CloseServiceHandle(h)

	name, _ := windows.UTF16PtrFromString(ServiceName())
	sh, err := windows.OpenService(h, name, windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return false
	}
	windows.CloseServiceHandle(sh)
	return true
}

// Install registers the Windows service. The binary path is set to
// "<exePath> _svc" so that SCM launches the CLI with the hidden _svc command.
// Idempotent: returns nil if the service already exists.
func Install(exePath string) error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to SCM: %w", err)
	}
	defer m.Disconnect()

	name := ServiceName()

	// Already exists — update the binary path and return.
	if s, err := m.OpenService(name); err == nil {
		cfg, err := s.Config()
		if err == nil {
			cfg.BinaryPathName = exePath + " _svc"
			_ = s.UpdateConfig(cfg)
		}
		s.Close()
		return nil
	}

	cfg := mgr.Config{
		DisplayName: "KVM Ubuntu VM Manager",
		Description: "为 " + buildinfo.AppName + " CLI 提供提权执行能力，避免重复 UAC 弹窗",
		StartType:   mgr.StartAutomatic,
	}
	s, err := m.CreateService(name, exePath, cfg, "_svc")
	if err != nil {
		return fmt.Errorf("create service: %w", err)
	}

	// Configure recovery: restart after 60s on failure.
	_ = s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}, 0)

	s.Close()
	return nil
}

// EnsureRunning starts the service if it exists and is not already running.
func EnsureRunning() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to SCM: %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName())
	if err != nil {
		return nil // not installed, skip
	}
	defer s.Close()

	status, err := s.Query()
	if err != nil {
		return fmt.Errorf("query service: %w", err)
	}
	if status.State == svc.Running {
		return nil
	}

	if err := s.Start(); err != nil {
		return fmt.Errorf("start service: %w", err)
	}

	// Wait up to 15s for the service to reach running state.
	for i := 0; i < 30; i++ {
		time.Sleep(500 * time.Millisecond)
		status, err = s.Query()
		if err != nil {
			return fmt.Errorf("query service: %w", err)
		}
		if status.State == svc.Running {
			return nil
		}
	}
	return fmt.Errorf("service did not start within 15s")
}

// Stop sends a stop signal to the service and waits for it to stop.
// Returns nil if the service is not installed or already stopped.
func Stop() error {
	m, err := mgr.Connect()
	if err != nil {
		return nil // not admin or SCM unavailable, skip
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName())
	if err != nil {
		return nil // not installed
	}
	defer s.Close()

	status, err := s.Query()
	if err != nil {
		return nil
	}
	if status.State == svc.Stopped {
		return nil
	}

	_, err = s.Control(svc.Stop)
	if err != nil {
		return fmt.Errorf("stop service: %w", err)
	}

	for i := 0; i < 30; i++ {
		time.Sleep(500 * time.Millisecond)
		status, err = s.Query()
		if err != nil {
			return nil
		}
		if status.State == svc.Stopped {
			return nil
		}
	}
	return fmt.Errorf("service did not stop within 15s")
}

// Uninstall stops and deletes the service.
// Returns nil if the service is not installed.
func Uninstall() error {
	if err := Stop(); err != nil {
		return err
	}

	m, err := mgr.Connect()
	if err != nil {
		return nil
	}
	defer m.Disconnect()

	s, err := m.OpenService(ServiceName())
	if err != nil {
		return nil // not installed
	}
	defer s.Close()

	return s.Delete()
}
