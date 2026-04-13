//go:build !windows

package winsvc

import (
	"fmt"
	"net"

	"github.com/SuLinXin66/vm-autoinstaller/internal/buildinfo"
)

func ServiceName() string   { return buildinfo.AppName + "-svc" }
func PipePath() string      { return "" }
func IsInstalled() bool     { return false }
func Install(string) error  { return fmt.Errorf("windows service not supported on this platform") }
func EnsureRunning() error  { return nil }
func Stop() error           { return nil }
func Uninstall() error      { return nil }
func Run() error            { return fmt.Errorf("windows service not supported on this platform") }
func TryConnect() (net.Conn, error) {
	return nil, fmt.Errorf("windows service not supported on this platform")
}
