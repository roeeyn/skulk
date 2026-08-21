package relay_test

import (
	"bytes"
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/roeeyn/skulk/internal/relay"
	"github.com/roeeyn/skulk/internal/testrelay"
)

// lockedBuffer: the read goroutine writes diagnostics while the test reads them.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}

// §18.2 is the whole point of this test, and it is a NEGATIVE requirement:
// "Debug output MUST never include message text or secret/key material."
//
// A rule kept only by call-site discipline is a rule one careless Sprintf
// undoes, so this asserts on the bytes that actually came out.
func TestDebugLogsProtocolShapeAndNeverContent(t *testing.T) {
	const (
		password = "correct-horse-battery-staple"
		secret   = "the-text-of-a-private-message"
		roomID   = "amber-river-copper-moon-forest-glass-harbor-star"
	)

	r := testrelay.New()
	t.Cleanup(r.Stop)

	log := &lockedBuffer{}
	session, err := relay.DialWithOptions(context.Background(), r.URL(),
		relay.Options{Keepalive: -1, Debug: log})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = session.Close() })

	if _, err := session.Create(context.Background(), roomID, password); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := session.Send(context.Background(), secret); err != nil {
		t.Fatalf("send: %v", err)
	}

	out := log.String()

	// Protocol states, event types and sizes — what §18.2 does allow.
	for _, want := range []string{"dialing", "connected", "send create.begin", "send chat.send", "bytes"} {
		if !strings.Contains(out, want) {
			t.Errorf("debug output is missing %q:\n%s", want, out)
		}
	}

	// And nothing else.
	for _, forbidden := range []struct{ what, value string }{
		{"the password", password},
		{"the message text", secret},
		{"the room id", roomID},
	} {
		if strings.Contains(out, forbidden.value) {
			t.Errorf("debug output leaked %s:\n%s", forbidden.what, out)
		}
	}
}

// Normal operation MUST not create diagnostics at all (§18.2). Nil is the switch.
func TestWithoutDebugNothingIsLogged(t *testing.T) {
	r := testrelay.New()
	t.Cleanup(r.Stop)

	session, err := relay.DialWithOptions(context.Background(), r.URL(), relay.Options{Keepalive: -1})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = session.Close() })

	if _, err := session.Create(context.Background(), "amber-river-copper-moon-forest-glass-harbor-star", "correct-horse-battery"); err != nil {
		t.Fatalf("create: %v", err)
	}
	// No writer, no panic, no output — the assertion is that this returns at all.
}
