//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
)

// The window is Windows-only (the Mac has its own native app); the MCP server and core run anywhere.
func runGUI(bool) {
	fmt.Fprintln(os.Stderr, "The TV Remote window is Windows-only. Run `tvremote mcp` for the MCP server.")
	os.Exit(2)
}

func hideWindow(*exec.Cmd) {}
