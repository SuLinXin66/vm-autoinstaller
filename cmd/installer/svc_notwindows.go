//go:build !windows

package main

func ensureElevated() bool            { return false }
func stopServiceBeforeCLI()           {}
func installAndStartService(_ string) {}
