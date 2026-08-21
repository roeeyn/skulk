// Command protocol-oracle exposes the Go protocol v0 validator to the Elixir test
// suite, so the two independent codecs (design A13) can be differentially tested
// against generated frames rather than only against the hand-written golden corpus.
//
// It is a test fixture, not a shipped tool. It exists because ROJ-44 needs to ask
// the Go validator about hundreds of thousands of frames, and starting a process
// per frame would dominate the runtime — so it is a long-lived filter driven
// through a Port, the way the integration suite drives real `skulk --headless`
// clients.
//
// # Protocol
//
// One request per line on stdin:
//
//	<receiver> <kind> <base64-frame>
//
// where receiver is `relay` or `client` and kind is `text` or `binary`. The frame
// is base64 because the whole point is to send bytes that are not valid UTF-8, not
// valid JSON, and quite possibly full of newlines.
//
// One response per line on stdout: `ok` for a frame the validator accepts, or the
// protocol §6 error code it rejects with. `ok` rather than an empty line on
// purpose — an empty line is indistinguishable from a desynchronised stream, and
// telling those apart at 3am is not a debugging session anyone needs.
//
// A malformed request answers `bad-request`, which no validator can return, so a
// harness bug cannot masquerade as a codec disagreement.
package main

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	"github.com/roeeyn/skulk/internal/protocol"
)

func main() {
	in := bufio.NewScanner(os.Stdin)
	// Frames run to the relay's 16 KiB cap, and a differential harness wants to
	// probe past it; base64 inflates by a third on top of that.
	in.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	out := bufio.NewWriter(os.Stdout)

	for in.Scan() {
		fmt.Fprintln(out, verdict(in.Text()))

		// Every line, without exception. A response sitting in this buffer is a
		// harness that blocks forever waiting for an answer that was computed.
		if err := out.Flush(); err != nil {
			os.Exit(1)
		}
	}
}

func verdict(line string) string {
	// Only the line terminator is trimmed, never spaces: an empty frame is a legal
	// thing to ask about, and TrimSpace would turn its trailing separator into a
	// two-field line and answer bad-request instead of a verdict.
	fields := strings.SplitN(strings.TrimRight(line, "\r\n"), " ", 3)
	if len(fields) != 3 {
		return "bad-request"
	}

	receiver, kind, encoded := protocol.Role(fields[0]), protocol.Kind(fields[1]), fields[2]
	if receiver != protocol.RoleRelay && receiver != protocol.RoleClient {
		return "bad-request"
	}
	if kind != protocol.KindText && kind != protocol.KindBinary {
		return "bad-request"
	}

	frame, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "bad-request"
	}

	// protocol.Validate and nothing else: it is the seam the golden corpus test
	// uses, so a differential result here speaks for the code that actually ships.
	if code := protocol.Validate(receiver, kind, frame); code != "" {
		return code
	}
	return "ok"
}
