package main

import (
	"strings"
	"testing"
)

// Amendment A15 and spec §20: a password on argv is visible in process listings
// and persists in shell history, so passing one is a usage error rather than
// something to accept quietly.
//
// The stdout assertion is the load-bearing half. docs/headless-v1.md §3 promises
// that stdout carries nothing but protocol JSON, and a usage message printed
// there would break that promise for every agent piping stdout into a parser.
func TestSecretFlagsAreRejectedBeforeAnythingElse(t *testing.T) {
	for _, args := range [][]string{
		{"--password", "hunter2hunter2"},
		{"--password=hunter2hunter2"},
		{"-password", "hunter2hunter2"},
		{"--headless", "--server", "wss://relay.example", "--password", "hunter2hunter2"},
		{"--passphrase", "correct-horse-battery"},
		{"--room-password", "correct-horse-battery"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			stdout := &strings.Builder{}
			stderr := &strings.Builder{}

			code := run(args, strings.NewReader(""), stdout, stderr, "")

			if code != 2 {
				t.Errorf("exit = %d, want 2 (usage error)", code)
			}
			if stdout.String() != "" {
				t.Errorf("stdout must stay empty so the JSON-only promise holds, got %q", stdout.String())
			}
			if !strings.Contains(stderr.String(), "argv") {
				t.Errorf("stderr should explain why, got %q", stderr.String())
			}
			// The refusal must never echo the secret it refused.
			if strings.Contains(stderr.String(), "hunter2hunter2") ||
				strings.Contains(stderr.String(), "correct-horse-battery") {
				t.Error("the refusal echoed the password back")
			}
		})
	}
}

func TestVersionPrintsToStdoutAndExitsZero(t *testing.T) {
	stdout := &strings.Builder{}
	stderr := &strings.Builder{}

	if code := run([]string{"--version"}, strings.NewReader(""), stdout, stderr, ""); code != 0 {
		t.Errorf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout.String(), "skulk") {
		t.Errorf("stdout = %q", stdout.String())
	}
}

// A10: no default relay, so headless mode without one is a usage error — and it
// must not reach the point of emitting protocol output.
func TestHeadlessWithoutAServerIsAUsageError(t *testing.T) {
	stdout := &strings.Builder{}
	stderr := &strings.Builder{}

	if code := run([]string{"--headless"}, strings.NewReader(""), stdout, stderr, ""); code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
	if stdout.String() != "" {
		t.Errorf("stdout must stay empty, got %q", stdout.String())
	}
	if !strings.Contains(stderr.String(), "SKULK_SERVER") {
		t.Errorf("stderr should name both configuration routes, got %q", stderr.String())
	}
}

// SKULK_SERVER is the documented fallback, so it must actually be consulted.
func TestServerComesFromTheEnvironmentWhenNoFlagIsGiven(t *testing.T) {
	stdout := &strings.Builder{}
	stderr := &strings.Builder{}

	// A loopback port with nothing on it: past the usage check, into a real dial
	// that fails as a transport error (exit 3) rather than a usage error.
	code := run([]string{"--headless"}, strings.NewReader(`{"command":"join","params":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"correct-horse-battery"}}`+"\n"),
		stdout, stderr, "ws://127.0.0.1:1/v1/ws")

	if code != 3 {
		t.Errorf("exit = %d, want 3 (transport); stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), `"event":"ready"`) {
		t.Errorf("headless mode should have started, stdout=%q", stdout.String())
	}
}
