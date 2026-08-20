// skulk — terminal chat client for humans and AI agents.
//
// M0: --headless line mode (newline-delimited JSON on stdin/stdout, the machine
// interface documented in docs/headless-v1.md and promised by amendment A15).
// The bubbletea TUI arrives in ROJ-34 on top of the same session layer.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/roeeyn/skulk/internal/headless"
	"github.com/roeeyn/skulk/internal/relay"
)

// Version is set at build time via -ldflags.
var Version = "0.0.0-dev"

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv("SKULK_SERVER")))
}

// run is main without the exit, so tests can drive the real argument handling.
func run(args []string, stdin io.Reader, stdout, stderr io.Writer, serverEnv string) int {
	// Checked before flag parsing so the message explains the rule rather than
	// just reporting an unknown flag. Amendment A15 and spec §20: a password on
	// argv is visible in process listings and persists in shell history, so this
	// is a usage error by design, not an oversight.
	if flagName := findForbiddenSecretFlag(args); flagName != "" {
		fmt.Fprintf(stderr, "skulk: %s is not accepted: secrets must never appear in argv, "+
			"where process listings and shell history expose them.\n"+
			"In --headless mode the password travels as JSON on stdin; see docs/headless-v1.md.\n", flagName)
		return headless.ExitUsage
	}

	fs := flag.NewFlagSet("skulk", flag.ContinueOnError)
	fs.SetOutput(stderr)

	var (
		showVersion   = fs.Bool("version", false, "print version and exit")
		headlessMode  = fs.Bool("headless", false, "machine interface: newline-delimited JSON on stdin/stdout")
		server        = fs.String("server", "", "relay WebSocket URL (or set SKULK_SERVER)")
		allowInsecure = fs.Bool("allow-insecure", false, "permit ws:// to a non-loopback host")
	)

	if err := fs.Parse(args); err != nil {
		return headless.ExitUsage
	}

	if *showVersion {
		fmt.Fprintln(stdout, "skulk", Version)
		return headless.ExitOK
	}

	if !*headlessMode {
		fmt.Fprintln(stderr, "skulk: the TUI is not implemented yet (ROJ-34). Use --headless for the machine interface.")
		return headless.ExitFailure
	}

	endpoint, err := relay.ResolveServer(*server, serverEnv)
	if err != nil {
		fmt.Fprintf(stderr, "skulk: %v\n", err)
		return headless.ExitUsage
	}

	runner := &headless.Runner{
		In:            stdin,
		Out:           stdout,
		Err:           stderr,
		Server:        endpoint,
		AllowInsecure: *allowInsecure,
		ClientVersion: Version,
	}
	return runner.Run(context.Background())
}

// findForbiddenSecretFlag reports a secret-bearing flag if one was passed, in any
// of the spellings Go's flag package would accept.
func findForbiddenSecretFlag(args []string) string {
	forbidden := []string{"password", "passphrase", "room-password"}

	for _, arg := range args {
		if !strings.HasPrefix(arg, "-") {
			continue
		}
		name := strings.TrimLeft(arg, "-")
		name, _, _ = strings.Cut(name, "=")

		for _, f := range forbidden {
			if name == f {
				return "--" + f
			}
		}
	}
	return ""
}
