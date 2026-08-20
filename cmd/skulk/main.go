// skulk — terminal chat client.
//
// M0: TUI (bubbletea) + --headless line mode (newline-delimited JSON on
// stdin/stdout; the machine interface for tests and AI agents — see
// docs/headless-v1.md and design amendment A15).
package main

import (
	"flag"
	"fmt"
	"os"
)

// Version is set at build time via -ldflags.
var Version = "0.0.0-dev"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println("skulk", Version)
		return
	}

	fmt.Fprintln(os.Stderr, "skulk: not yet implemented — see Linear project 'skulk M0'")
	os.Exit(1)
}
