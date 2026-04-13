//go:build windows

package winsvc

import (
	"net"
	"time"

	"github.com/Microsoft/go-winio"
)

// TryConnect attempts to connect to the service Named Pipe.
// Used by the installer to verify the service is running.
func TryConnect() (net.Conn, error) {
	timeout := 2 * time.Second
	conn, err := winio.DialPipe(PipePath(), &timeout)
	if err != nil {
		return nil, err
	}
	return conn, nil
}
