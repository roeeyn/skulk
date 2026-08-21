package relay_test

import (
	"context"
	"testing"
	"time"

	"github.com/roeeyn/skulk/internal/relay"
	"github.com/roeeyn/skulk/internal/testrelay"
)

// A session that sits idle must keep pinging.
//
// Regression test for a real disconnect: the relay's WebSocket idle timeout closes
// a silent connection with code 1002 (Bandit's handle_timeout), and ten minutes of
// not typing is ordinary — you read a long message and think. Protocol v0 §5.10
// specified ping/pong for exactly this, and both sides implemented it, but nothing
// ever SENT one, so every session had a ten-minute fuse.
func TestIdleSessionKeepsPinging(t *testing.T) {
	r := testrelay.New()
	defer r.Stop()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	session, err := relay.DialWithOptions(ctx, r.URL(), relay.Options{Keepalive: 40 * time.Millisecond})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer session.Close()

	// The session is never used for anything after this point — that is the case
	// under test.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if r.Pings() >= 3 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("an idle session sent %d pings in 5s; it must keep the connection alive", r.Pings())
}

// The keepalive must stop when the session does, rather than pinging a closed
// socket forever.
func TestKeepaliveStopsWithTheSession(t *testing.T) {
	r := testrelay.New()
	defer r.Stop()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	session, err := relay.DialWithOptions(ctx, r.URL(), relay.Options{Keepalive: 20 * time.Millisecond})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}

	time.Sleep(120 * time.Millisecond)
	if err := session.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	settled := r.Pings()
	time.Sleep(300 * time.Millisecond)

	if grew := r.Pings() - settled; grew > 1 {
		t.Errorf("keepalive kept running after Close: %d further pings", grew)
	}
}

// Keepalive: -1 disables it, which the relay-side timeout tests need.
func TestKeepaliveCanBeDisabled(t *testing.T) {
	r := testrelay.New()
	defer r.Stop()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	session, err := relay.DialWithOptions(ctx, r.URL(), relay.Options{Keepalive: -1})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer session.Close()

	time.Sleep(200 * time.Millisecond)
	if got := r.Pings(); got != 0 {
		t.Errorf("keepalive was disabled but sent %d pings", got)
	}
}
