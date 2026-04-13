//go:build windows

package winsvc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os/exec"
	"path/filepath"
	"sync"
)

func handleConnection(conn net.Conn) {
	defer conn.Close()

	var req ExecRequest
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		writeMsg(conn, StreamMsg{Type: "err", Data: fmt.Sprintf("bad request: %v\n", err)})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}

	switch req.Type {
	case "exec":
		handleExec(conn, &req)
	case "cmd":
		handleCmd(conn, &req)
	default:
		writeMsg(conn, StreamMsg{Type: "err", Data: fmt.Sprintf("unknown request type: %s\n", req.Type)})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
	}
}

// handleExec runs a .ps1 script file (legacy path, kept for _svc-install etc.)
func handleExec(conn net.Conn, req *ExecRequest) {
	if req.Script == "" {
		writeMsg(conn, StreamMsg{Type: "err", Data: "empty script name\n"})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}

	scriptDir := req.Env["__SCRIPT_DIR"]
	if scriptDir == "" {
		writeMsg(conn, StreamMsg{Type: "err", Data: "__SCRIPT_DIR not set\n"})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}

	ps1 := filepath.Join(scriptDir, req.Script+".ps1")
	psArgs := []string{"-ExecutionPolicy", "Bypass", "-NoProfile", "-File", ps1}
	psArgs = append(psArgs, req.Args...)

	runAndStream(conn, "powershell.exe", psArgs, nil)
}

// handleCmd runs an inline PowerShell command string.
// This is the "sudo" path — called by Invoke-Elevated from PowerShell scripts.
func handleCmd(conn net.Conn, req *ExecRequest) {
	if req.Command == "" {
		writeMsg(conn, StreamMsg{Type: "err", Data: "empty command\n"})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}

	psArgs := []string{"-ExecutionPolicy", "Bypass", "-NoProfile", "-Command", req.Command}
	runAndStream(conn, "powershell.exe", psArgs, nil)
}

// runAndStream starts a child process, streams stdout/stderr back to the
// named-pipe client, and sends a "done" message with the exit code.
func runAndStream(conn net.Conn, exe string, args []string, env []string) {
	cmd := exec.Command(exe, args...)
	if len(env) > 0 {
		cmd.Env = env
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeMsg(conn, StreamMsg{Type: "err", Data: fmt.Sprintf("stdout pipe: %v\n", err)})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		writeMsg(conn, StreamMsg{Type: "err", Data: fmt.Sprintf("stderr pipe: %v\n", err)})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}

	if err := cmd.Start(); err != nil {
		writeMsg(conn, StreamMsg{Type: "err", Data: fmt.Sprintf("start failed: %v\n", err)})
		writeMsg(conn, StreamMsg{Type: "done", Code: 1})
		return
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go streamPipe(&wg, conn, stdout, "out")
	go streamPipe(&wg, conn, stderr, "err")
	wg.Wait()

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = 1
		}
	}
	writeMsg(conn, StreamMsg{Type: "done", Code: exitCode})
}

func streamPipe(wg *sync.WaitGroup, conn net.Conn, r io.Reader, msgType string) {
	defer wg.Done()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		writeMsg(conn, StreamMsg{Type: msgType, Data: scanner.Text() + "\n"})
	}
}

var writeMu sync.Mutex

func writeMsg(conn net.Conn, msg StreamMsg) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("winsvc: marshal error: %v", err)
		return
	}
	data = append(data, '\n')
	writeMu.Lock()
	conn.Write(data)
	writeMu.Unlock()
}
