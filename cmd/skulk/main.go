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

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/roeeyn/skulk/internal/headless"
	"github.com/roeeyn/skulk/internal/relay"
	"github.com/roeeyn/skulk/internal/tui"
	"github.com/roeeyn/skulk/internal/wordlist"
)

// Version is set at build time via -ldflags.
var Version = "0.0.0-dev"

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr,
		os.Getenv("SKULK_SERVER"), os.Getenv("NO_COLOR")))
}

// run is main without the exit, so tests can drive the real argument handling.
func run(args []string, stdin io.Reader, stdout, stderr io.Writer, serverEnv, noColorEnv string) int {
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

	// Spec §7.1's subcommand surface. `serve` is deliberately absent: amendment
	// A13 retired it when the relay became a separate Elixir application.
	var subcommand, roomID string
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		subcommand, args = args[0], args[1:]

		// `skulk join <ROOM_ID> [flags]` — pulled out before flag parsing, which
		// otherwise stops at the first positional and leaves the flags unparsed.
		if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
			roomID, args = args[0], args[1:]
		}
	}

	fs := flag.NewFlagSet("skulk", flag.ContinueOnError)
	fs.SetOutput(stderr)

	var (
		showVersion   = fs.Bool("version", false, "print version and exit")
		headlessMode  = fs.Bool("headless", false, "machine interface: newline-delimited JSON on stdin/stdout")
		server        = fs.String("server", "", "relay WebSocket URL (or set SKULK_SERVER)")
		allowInsecure = fs.Bool("allow-insecure", false, "permit ws:// to a non-loopback host")
		noColor       = fs.Bool("no-color", false, "disable ANSI colors (spec §7.2)")
		debug         = fs.Bool("debug", false, "diagnostic logging to stderr; never secrets or message text (§18.2)")
	)

	if err := fs.Parse(args); err != nil {
		return headless.ExitUsage
	}

	// Before anything renders. lipgloss decides the profile from the output at
	// first use, so forcing it has to happen ahead of the first Render call.
	applyColorChoice(*noColor, noColorEnv)

	if *showVersion {
		fmt.Fprintln(stdout, "skulk", Version)
		return headless.ExitOK
	}

	if roomID == "" {
		roomID = fs.Arg(0)
	}

	endpoint, err := relay.ResolveServer(*server, serverEnv)
	if err != nil {
		fmt.Fprintf(stderr, "skulk: %v\n", err)
		return headless.ExitUsage
	}

	if *headlessMode {
		runner := &headless.Runner{
			In:            stdin,
			Out:           stdout,
			Err:           stderr,
			Server:        endpoint,
			AllowInsecure: *allowInsecure,
			ClientVersion: Version,
			Debug:         *debug,
		}
		return runner.Run(context.Background())
	}

	switch subcommand {
	case "create":
		return runTUI(endpoint, "", false, *allowInsecure, *debug, stdin, stdout, stderr)

	case "join":
		if roomID == "" {
			fmt.Fprintln(stderr, "skulk: join needs a room id: skulk join <ROOM_ID>")
			return headless.ExitUsage
		}
		return runTUI(endpoint, roomID, true, *allowInsecure, *debug, stdin, stdout, stderr)

	case "":
		fmt.Fprintln(stderr, usage)
		return headless.ExitUsage

	default:
		fmt.Fprintf(stderr, "skulk: unknown command %q\n\n%s\n", subcommand, usage)
		return headless.ExitUsage
	}
}

const usage = `skulk — terminal chat for humans and AI agents

  skulk create [--server URL]              create a room and join it
  skulk join <ROOM_ID> [--server URL]      join an existing room
  skulk --headless [--server URL]          machine interface (docs/headless-v1.md)
  skulk --version

The relay URL comes from --server or SKULK_SERVER; skulk ships no default relay.`

func runTUI(endpoint, roomID string, joining, allowInsecure, debug bool, stdin io.Reader, stdout, stderr io.Writer) int {
	if _, err := relay.CheckServerURL(endpoint, allowInsecure); err != nil {
		fmt.Fprintf(stderr, "skulk: %v\n", err)
		return headless.ExitTransport
	}

	model := tui.New(tui.Config{
		Server:    endpoint,
		RoomID:    roomID,
		Joining:   joining,
		Dial:      tui.DialRelayWith(relay.Options{Debug: debugWriter(debug, stderr)}),
		Generate:  wordlist.NewPassphrase,
		NewRoomID: wordlist.NewRoomID,
	})

	program := tui.NewProgram(model, tea.WithInput(stdin), tea.WithOutput(stdout))

	final, err := program.Run()
	if err != nil {
		fmt.Fprintf(stderr, "skulk: %v\n", err)
		return headless.ExitFailure
	}

	// bubbletea's Quit carries no exit status, so the model records the outcome
	// and the mapping to spec §17's table happens here — nothing in the TUI calls
	// os.Exit, which is also what keeps it testable.
	if m, ok := final.(tui.Model); ok {
		// The program runs full-screen, and leaving the alternate screen restores
		// whatever the terminal held before skulk started — taking the last frame,
		// and any explanation on it, with it. Anything the user still needs to read
		// has to be printed here, after the restore.
		if reason := m.Reason(); reason != "" {
			fmt.Fprintf(stderr, "skulk: %s\n", reason)
		}
		return m.Outcome().ExitCode()
	}
	return headless.ExitOK
}

// debugWriter is stderr when --debug asked for diagnostics, and nil otherwise.
//
// Worth knowing before using it with the TUI: the program runs full-screen and
// stderr is the same terminal, so diagnostics scribble over the display.
// §18.2 mandates stderr, so the answer is a redirect — `skulk create --debug
// 2>skulk.log` — not a different destination.
func debugWriter(debug bool, stderr io.Writer) io.Writer {
	if !debug {
		return nil
	}
	return stderr
}

// applyColorChoice honours spec §7.2's --no-color, and NO_COLOR alongside it.
//
// NO_COLOR is the de facto standard (no-color.org): what matters is that the
// variable is PRESENT and non-empty, not what it is set to, so `NO_COLOR=0` also
// disables colour. That reads wrong and is the specified behaviour.
func applyColorChoice(noColor bool, noColorEnv string) {
	if noColor || noColorEnv != "" {
		lipgloss.SetColorProfile(termenv.Ascii)
	}
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
