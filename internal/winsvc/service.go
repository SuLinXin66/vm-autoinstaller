//go:build windows

package winsvc

import (
	"log"
	"net"
	"sync"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows/svc"
)

// Run is the service entry point called by SCM via the hidden "_svc" command.
// It blocks until the service is stopped.
func Run() error {
	return svc.Run(ServiceName(), &handler{})
}

type handler struct{}

func (h *handler) Execute(args []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	s <- svc.Status{State: svc.StartPending}

	listener, err := winio.ListenPipe(PipePath(), &winio.PipeConfig{
		SecurityDescriptor: "D:(A;;GRGW;;;AU)", // Authenticated Users: read+write
		MessageMode:        false,
	})
	if err != nil {
		log.Printf("winsvc: listen pipe failed: %v", err)
		s <- svc.Status{State: svc.StopPending}
		return false, 1
	}

	var wg sync.WaitGroup
	done := make(chan struct{})

	// Accept loop
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				select {
				case <-done:
					return
				default:
					log.Printf("winsvc: accept error: %v", err)
					continue
				}
			}
			wg.Add(1)
			go func(c net.Conn) {
				defer wg.Done()
				handleConnection(c)
			}(conn)
		}
	}()

	s <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

	for cr := range r {
		switch cr.Cmd {
		case svc.Stop, svc.Shutdown:
			s <- svc.Status{State: svc.StopPending}
			close(done)
			listener.Close()
			wg.Wait()
			return false, 0
		case svc.Interrogate:
			s <- cr.CurrentStatus
		}
	}
	return false, 0
}
