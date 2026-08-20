package relay_test

import (
	"strings"
	"testing"

	"github.com/roeeyn/skulk/internal/relay"
)

// Spec §7.2: wss:// always, ws:// only for loopback or with an explicit opt-in.
// The rule matters because at M0 the room password crosses this connection in the
// clear inside the frame — TLS is the only thing protecting it.
func TestCheckServerURL(t *testing.T) {
	cases := []struct {
		name          string
		url           string
		allowInsecure bool
		wantErr       bool
	}{
		{"wss to a remote host", "wss://relay.example/v1/ws", false, false},
		{"ws to a remote host is refused", "ws://relay.example/v1/ws", false, true},
		{"ws to a remote host with the opt-in", "ws://relay.example/v1/ws", true, false},
		{"ws to 127.0.0.1", "ws://127.0.0.1:4000/v1/ws", false, false},
		{"ws to localhost", "ws://localhost:4000/v1/ws", false, false},
		{"ws to ::1", "ws://[::1]:4000/v1/ws", false, false},
		{"ws to a 127.x address", "ws://127.0.0.53:4000/v1/ws", false, false},
		// 0.0.0.0 is NOT loopback: it routes off-box and the password would leave
		// the machine in the clear.
		{"ws to 0.0.0.0 is refused", "ws://0.0.0.0:4000/v1/ws", false, true},
		{"a public IP is refused", "ws://93.184.216.34/v1/ws", false, true},
		{"http is not a websocket scheme", "http://relay.example/v1/ws", false, true},
		{"a bare host has no scheme", "relay.example/v1/ws", false, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := relay.CheckServerURL(tc.url, tc.allowInsecure)
			if tc.wantErr && err == nil {
				t.Fatalf("CheckServerURL(%q, %v) succeeded, want an error", tc.url, tc.allowInsecure)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("CheckServerURL(%q, %v) = %v, want success", tc.url, tc.allowInsecure, err)
			}
		})
	}
}

// The refusal has to teach, not just deny: a user who sees it should understand
// why and what the escape hatch is.
func TestInsecureRefusalExplainsItself(t *testing.T) {
	_, err := relay.CheckServerURL("ws://relay.example/v1/ws", false)
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, want := range []string{"clear", "wss://", "--allow-insecure"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal should mention %q, got: %v", want, err)
		}
	}
}

// Spec §7.2 precedence, and amendment A10's deliberate absence of a third rung:
// skulk ships no default relay, so with neither source configured this must fail
// rather than silently pointing somewhere.
func TestResolveServerPrecedence(t *testing.T) {
	if got, _ := relay.ResolveServer("wss://flag.example", "wss://env.example"); got != "wss://flag.example" {
		t.Errorf("the flag must win, got %q", got)
	}
	if got, _ := relay.ResolveServer("", "wss://env.example"); got != "wss://env.example" {
		t.Errorf("SKULK_SERVER must be used when no flag is given, got %q", got)
	}

	_, err := relay.ResolveServer("", "")
	if err == nil {
		t.Fatal("with no relay configured this must fail: A10 removed the built-in default")
	}
	if !strings.Contains(err.Error(), "--server") {
		t.Errorf("the error should name the flag, got: %v", err)
	}
}
