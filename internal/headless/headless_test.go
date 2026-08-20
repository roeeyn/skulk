package headless_test

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/roeeyn/skulk/internal/headless"
	"github.com/roeeyn/skulk/internal/testrelay"
)

// agent drives one headless process the way an AI agent or the ExUnit harness
// does: JSON lines in, JSON lines out.
type agent struct {
	t      *testing.T
	stdin  *io.PipeWriter
	stdout *bufio.Reader
	stderr *strings.Builder
	exit   chan int
	mu     sync.Mutex
}

func start(t *testing.T, server string) *agent {
	t.Helper()

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	stderr := &strings.Builder{}

	a := &agent{
		t: t, stdin: inW, stdout: bufio.NewReaderSize(outR, 1<<20),
		stderr: stderr, exit: make(chan int, 1),
	}

	runner := &headless.Runner{
		In: inR, Out: outW, Err: stderr,
		Server: server, ClientVersion: "test",
	}
	go func() {
		code := runner.Run(context.Background())
		outW.Close()
		a.exit <- code
	}()

	t.Cleanup(func() { inW.Close() })
	return a
}

func (a *agent) send(line string) {
	a.t.Helper()
	if _, err := io.WriteString(a.stdin, line+"\n"); err != nil {
		a.t.Fatalf("writing to stdin: %v", err)
	}
}

// next reads one event, failing the test on timeout rather than hanging.
func (a *agent) next() map[string]any {
	a.t.Helper()

	type read struct {
		line string
		err  error
	}
	ch := make(chan read, 1)
	go func() {
		line, err := a.stdout.ReadString('\n')
		ch <- read{line, err}
	}()

	select {
	case r := <-ch:
		if r.err != nil && r.line == "" {
			a.t.Fatalf("stdout closed while waiting for an event (stderr: %s)", a.stderr.String())
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(strings.TrimSpace(r.line)), &event); err != nil {
			a.t.Fatalf("stdout line is not JSON: %q", r.line)
		}
		return event
	case <-time.After(5 * time.Second):
		a.t.Fatalf("timed out waiting for an event (stderr: %s)", a.stderr.String())
		return nil
	}
}

// await skips unsolicited events until one of the wanted kind arrives. Ordering
// between pushes and responses is explicitly not promised (docs/headless-v1.md §11).
func (a *agent) await(event string) map[string]any {
	a.t.Helper()
	for i := 0; i < 20; i++ {
		e := a.next()
		if e["event"] == event {
			return e
		}
	}
	a.t.Fatalf("never saw a %q event", event)
	return nil
}

func (a *agent) code() int {
	a.t.Helper()
	select {
	case c := <-a.exit:
		return c
	case <-time.After(5 * time.Second):
		a.t.Fatal("process did not exit")
		return -1
	}
}

func data(event map[string]any) map[string]any {
	d, _ := event["data"].(map[string]any)
	return d
}

func fakeRelay(t *testing.T) *testrelay.Relay {
	t.Helper()
	r := testrelay.New()
	t.Cleanup(r.Stop)
	return r
}

// ---------------------------------------------------------------------------

// The startup handshake: ready is the FIRST line, before any network activity.
func TestReadyIsTheFirstLineAndPrecedesConnection(t *testing.T) {
	a := start(t, "wss://relay.invalid/v1/ws")

	ready := a.next()
	if ready["event"] != "ready" {
		t.Fatalf("first line is %v, want ready", ready["event"])
	}
	if ready["headless_version"] != float64(headless.Version) {
		t.Errorf("headless_version = %v, want %d", ready["headless_version"], headless.Version)
	}
	if ready["protocol_version"] != float64(0) {
		t.Errorf("protocol_version = %v, want 0", ready["protocol_version"])
	}
}

// The documented two-agent conversation, replayed against a real socket.
// docs/headless-v1.md §13 is the source; matching is shape-for-shape because
// usernames, sender_ids, sequences and timestamps are assigned at runtime.
func TestTwoAgentsHoldAConversation(t *testing.T) {
	relay := fakeRelay(t)

	alice := start(t, relay.URL())
	alice.await("ready")
	alice.send(`{"id":"c1","command":"create","params":{}}`)
	alice.await("connected")

	created := data(alice.await("created"))
	roomID, _ := created["room_id"].(string)
	password, _ := created["password"].(string)

	// §5.1: the generated passphrase is RETURNED. Without this, unattended create
	// would produce a room nobody could be invited to.
	if password == "" {
		t.Fatal("created must return the generated password")
	}
	if len(strings.Split(password, "-")) < 6 {
		t.Errorf("generated password %q does not look like a six-word passphrase", password)
	}
	if got := len(strings.Split(roomID, "-")); got != 8 {
		t.Errorf("room_id %q has %d words, want 8", roomID, got)
	}

	bob := start(t, relay.URL())
	bob.await("ready")
	bob.send(`{"id":"j1","command":"join","params":{"room_id":"` + roomID + `","password":"` + password + `"}}`)
	bob.await("connected")

	joined := data(bob.await("joined"))
	if joined["room_id"] != roomID {
		t.Errorf("joined room_id = %v, want %v", joined["room_id"], roomID)
	}
	if joined["snapshot_sequence"] != float64(0) {
		t.Errorf("empty history must report snapshot_sequence 0, got %v", joined["snapshot_sequence"])
	}

	// Alice learns Bob arrived.
	presence := data(alice.await("presence"))
	if presence["action"] != "joined" {
		t.Errorf("presence action = %v, want joined", presence["action"])
	}

	// Alice sends; both see it; only Alice's copy is self.
	alice.send(`{"id":"s1","command":"send","params":{"text":"hello from agent A"}}`)
	accepted := data(alice.await("accepted"))
	messageID, _ := accepted["message_id"].(string)
	if messageID == "" {
		t.Fatal("accepted must return the client-generated message_id")
	}

	alicesCopy := data(alice.await("message"))
	bobsCopy := data(bob.await("message"))

	// §5.3: accepted means "on the wire"; the echo carrying the same message_id is
	// the confirmation. That pairing is amendment A1d's self-suppression check.
	if alicesCopy["message_id"] != messageID {
		t.Errorf("echo message_id = %v, want the accepted id %v", alicesCopy["message_id"], messageID)
	}
	if alicesCopy["self"] != true {
		t.Error("the sender's own copy must carry self:true")
	}
	if bobsCopy["self"] != false {
		t.Error("a recipient's copy must carry self:false")
	}
	if bobsCopy["text"] != "hello from agent A" {
		t.Errorf("text = %v", bobsCopy["text"])
	}
	if bobsCopy["sequence"] != float64(1) {
		t.Errorf("sequence = %v, want 1", bobsCopy["sequence"])
	}

	// Bob replies with multi-byte text, and Alice sees it.
	bob.send(`{"id":"s2","command":"send","params":{"text":"hello back from agent B 🦊"}}`)
	bob.await("accepted")
	reply := data(alice.await("message"))
	if reply["text"] != "hello back from agent B 🦊" {
		t.Errorf("unicode text round-trip failed: %v", reply["text"])
	}

	// who
	alice.send(`{"id":"w1","command":"who","params":{}}`)
	roster := data(alice.await("participants"))
	if roster["participant_count"] != float64(2) {
		t.Errorf("participant_count = %v, want 2", roster["participant_count"])
	}

	// quit, exit 0
	bob.send(`{"id":"q1","command":"quit","params":{}}`)
	if bye := bob.await("bye"); bye["id"] != "q1" {
		t.Errorf("bye must echo the command id, got %v", bye["id"])
	}
	if code := bob.code(); code != headless.ExitOK {
		t.Errorf("quit exit code = %d, want 0", code)
	}

	alice.send(`{"id":"q2","command":"quit","params":{}}`)
	alice.await("bye")
	if code := alice.code(); code != headless.ExitOK {
		t.Errorf("quit exit code = %d, want 0", code)
	}
}

// A joiner receives retained history inline, with the boundary that separates it
// from live traffic (protocol §5.4).
func TestJoinReceivesHistorySnapshot(t *testing.T) {
	relay := fakeRelay(t)

	alice := start(t, relay.URL())
	alice.await("ready")
	alice.send(`{"id":"c1","command":"create","params":{}}`)
	alice.await("connected")
	created := data(alice.await("created"))
	roomID := created["room_id"].(string)
	password := created["password"].(string)

	for _, text := range []string{"first", "second", "third"} {
		alice.send(`{"command":"send","params":{"text":"` + text + `"}}`)
		alice.await("accepted")
		alice.await("message")
	}

	bob := start(t, relay.URL())
	bob.await("ready")
	bob.send(`{"id":"j1","command":"join","params":{"room_id":"` + roomID + `","password":"` + password + `"}}`)
	bob.await("connected")
	joined := data(bob.await("joined"))

	history, _ := joined["history"].([]any)
	if len(history) != 3 {
		t.Fatalf("history has %d messages, want 3", len(history))
	}
	if joined["snapshot_sequence"] != float64(3) {
		t.Errorf("snapshot_sequence = %v, want 3", joined["snapshot_sequence"])
	}
	for i, want := range []string{"first", "second", "third"} {
		entry := history[i].(map[string]any)
		if entry["text"] != want {
			t.Errorf("history[%d] = %v, want %v", i, entry["text"], want)
		}
		if entry["sequence"] != float64(i+1) {
			t.Errorf("history[%d] sequence = %v, want %d", i, entry["sequence"], i+1)
		}
	}
}

// docs/headless-v1.md §8: the §17 exit-code table, exercised end to end.
func TestExitCodes(t *testing.T) {
	t.Run("wrong password exits 5", func(t *testing.T) {
		relay := fakeRelay(t)

		alice := start(t, relay.URL())
		alice.await("ready")
		alice.send(`{"id":"c1","command":"create","params":{}}`)
		alice.await("connected")
		created := data(alice.await("created"))

		bob := start(t, relay.URL())
		bob.await("ready")
		bob.send(`{"id":"j1","command":"join","params":{"room_id":"` + created["room_id"].(string) + `","password":"definitely-not-the-password"}}`)
		bob.await("connected")

		e := data(bob.await("error"))
		if e["code"] != "authentication_failed" {
			t.Errorf("code = %v, want authentication_failed", e["code"])
		}
		if e["source"] != "wire" {
			t.Errorf("source = %v, want wire", e["source"])
		}
		// Decision H1: fatal, even though the wire keeps the connection open. A
		// process has no one to ask for a corrected password.
		if e["fatal"] != true {
			t.Error("a failed join must be fatal in headless mode")
		}
		if code := bob.code(); code != headless.ExitAuth {
			t.Errorf("exit = %d, want %d", code, headless.ExitAuth)
		}
	})

	t.Run("unknown room exits 4", func(t *testing.T) {
		relay := fakeRelay(t)

		a := start(t, relay.URL())
		a.await("ready")
		a.send(`{"id":"j1","command":"join","params":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"correct-horse-battery"}}`)
		a.await("connected")

		if e := data(a.await("error")); e["code"] != "room_not_found" {
			t.Errorf("code = %v, want room_not_found", e["code"])
		}
		if code := a.code(); code != headless.ExitNoRoom {
			t.Errorf("exit = %d, want %d", code, headless.ExitNoRoom)
		}
	})

	t.Run("refused connection exits 3", func(t *testing.T) {
		// A port nothing is listening on: loopback, so the ws:// policy allows it
		// and the failure is genuinely the connection, not the URL check.
		a := start(t, "ws://127.0.0.1:1/v1/ws")
		a.await("ready")
		a.send(`{"id":"j1","command":"join","params":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"correct-horse-battery"}}`)

		e := data(a.await("error"))
		if e["source"] != "client" || e["code"] != "transport" {
			t.Errorf("got source=%v code=%v, want client/transport", e["source"], e["code"])
		}
		if code := a.code(); code != headless.ExitTransport {
			t.Errorf("exit = %d, want %d", code, headless.ExitTransport)
		}
	})

	t.Run("room expiry exits 4", func(t *testing.T) {
		relay := fakeRelay(t)

		a := start(t, relay.URL())
		a.await("ready")
		a.send(`{"id":"c1","command":"create","params":{}}`)
		a.await("connected")
		created := data(a.await("created"))

		relay.Expire(created["room_id"].(string))

		expired := data(a.await("room_expired"))
		if expired["room_id"] != created["room_id"] {
			t.Errorf("room_id = %v", expired["room_id"])
		}
		if code := a.code(); code != headless.ExitNoRoom {
			t.Errorf("exit = %d, want %d", code, headless.ExitNoRoom)
		}
	})
}

// Agents mistype. One bad line must produce a diagnosis, not a dead process
// (docs/headless-v1.md §7.3).
func TestMalformedInputIsRecoverable(t *testing.T) {
	relay := fakeRelay(t)

	a := start(t, relay.URL())
	a.await("ready")

	cases := []struct {
		name string
		line string
		code string
	}{
		{"not JSON at all", `this is not json`, "invalid_command"},
		{"unknown command", `{"id":"x","command":"snd","params":{"text":"typo"}}`, "invalid_command"},
		{"send before joining", `{"id":"y","command":"send","params":{"text":"too early"}}`, "not_joined"},
		{"who before joining", `{"id":"z","command":"who","params":{}}`, "not_joined"},
		{"wrong param type", `{"id":"w","command":"send","params":{"text":42}}`, "invalid_command"},
	}

	for _, tc := range cases {
		a.send(tc.line)
		e := data(a.await("error"))
		if e["code"] != tc.code {
			t.Errorf("%s: code = %v, want %v", tc.name, e["code"], tc.code)
		}
		if e["source"] != "client" {
			t.Errorf("%s: source = %v, want client", tc.name, e["source"])
		}
		if e["fatal"] != false {
			t.Errorf("%s: must not be fatal", tc.name)
		}
	}

	// Still alive and still usable after all of that.
	a.send(`{"id":"c1","command":"create","params":{}}`)
	a.await("connected")
	if created := data(a.await("created")); created["room_id"] == "" {
		t.Error("session unusable after recoverable errors")
	}
}

// §3.1: an over-long line is rejected and DISCARDED THROUGH ITS NEWLINE, so the
// next command still frames correctly. Without that, one oversized line would
// corrupt every command after it.
func TestOversizedLineIsRejectedWithoutCorruptingTheStream(t *testing.T) {
	relay := fakeRelay(t)

	a := start(t, relay.URL())
	a.await("ready")

	huge := strings.Repeat("p", headless.MaxLineBytes+100)
	a.send(`{"command":"send","params":{"text":"` + huge + `"}}`)

	if e := data(a.await("error")); e["code"] != "invalid_command" {
		t.Errorf("code = %v, want invalid_command", e["code"])
	}

	a.send(`{"id":"after","command":"create","params":{}}`)
	a.await("connected")
	if created := a.await("created"); created["id"] != "after" {
		t.Errorf("stream framing broken after an oversized line: %v", created)
	}
}

// §5.5 / decision H2: closing stdin is quit. This is the shutdown path an Elixir
// Port uses, so it is specified rather than left to chance.
func TestClosingStdinIsQuit(t *testing.T) {
	relay := fakeRelay(t)

	a := start(t, relay.URL())
	a.await("ready")
	a.stdin.Close()

	if bye := a.await("bye"); bye["event"] != "bye" {
		t.Errorf("closing stdin must emit bye, got %v", bye)
	}
	if code := a.code(); code != headless.ExitOK {
		t.Errorf("exit = %d, want 0", code)
	}
}

// §3: stdout carries nothing but this protocol, so an agent can pipe it straight
// into a JSON parser. Diagnostics go to stderr.
func TestStdoutIsOnlyJSON(t *testing.T) {
	relay := fakeRelay(t)

	stdout := &strings.Builder{}
	stderr := &strings.Builder{}
	stdin, stdinW := io.Pipe()

	runner := &headless.Runner{In: stdin, Out: stdout, Err: stderr, Server: relay.URL(), ClientVersion: "test"}
	done := make(chan int, 1)
	go func() { done <- runner.Run(context.Background()) }()

	for _, line := range []string{
		`garbage that is not json`,
		`{"command":"send","params":{"text":"before joining"}}`,
		`{"id":"c1","command":"create","params":{}}`,
		`{"id":"q1","command":"quit","params":{}}`,
	} {
		io.WriteString(stdinW, line+"\n")
		time.Sleep(50 * time.Millisecond)
	}
	stdinW.Close()
	<-done

	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(lines) < 4 {
		t.Fatalf("expected several events, got %d: %q", len(lines), stdout.String())
	}
	for i, line := range lines {
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Errorf("stdout line %d is not a JSON object: %q", i, line)
			continue
		}
		if _, ok := event["event"].(string); !ok {
			t.Errorf("stdout line %d has no event field: %q", i, line)
		}
	}
}
