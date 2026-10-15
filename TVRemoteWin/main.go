package main

import (
	"fmt"
	"os"
	"slices"
)

const version_ = "2.0.1"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "mcp" {
		fmt.Fprintln(os.Stderr, "tv-remote-mcp: ready")
		serveMCP(os.Stdin, os.Stdout, &session{})
		return
	}
	runGUI(slices.Contains(os.Args[1:], "--hidden"))
}
