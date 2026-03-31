//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

func isDoubleClicked() bool {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	proc := kernel32.NewProc("GetConsoleProcessList")

	// GetConsoleProcessList returns the number of processes attached
	// to the current console. If only 1 (ourselves), we own the console
	// — meaning we were launched by double-click (Explorer created it).
	var pids [2]uint32
	count, _, _ := proc.Call(
		uintptr(unsafe.Pointer(&pids[0])),
		2,
	)
	return count <= 1
}
