package tui_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/exp/teatest"
	"github.com/muesli/termenv"

	"github.com/roeeyn/skulk/internal/protocol"
	"github.com/roeeyn/skulk/internal/relay"
	"github.com/roeeyn/skulk/internal/tui"
)

func init() {
	// Without this, rendered frames carry ANSI colour on a developer's terminal
	// and none in CI, so substring assertions pass locally and fail remotely.
	lipgloss.SetColorProfile(termenv.Ascii)
}

const suggested = "lentil-quartz-harbor-dusk-maple-wren"

// fakeSession stands in for a relay connection. Every test in this file uses it:
// the TUI's job is rendering and key handling, and proving those against a real
// socket would be slow, flaky, and testing something ROJ-35 already covers.
type fakeSession struct {
	events    chan relay.Event
	createErr error
	joinErr   error
	whoErr    error
	info      *relay.Info

	// bubbletea runs Cmds on their own goroutines, so anything a Cmd touches and a
	// test reads needs a lock. Found by -race, which is why CI runs it.
	mu      sync.Mutex
	sent    []string
	created string
	closed  bool
}

func newFakeSession(info *relay.Info) *fakeSession {
	return &fakeSession{events: make(chan relay.Event, 16), info: info}
}

func (f *fakeSession) Create(_ context.Context, roomID, _ string) (*relay.Info, error) {
	if f.createErr != nil {
		return nil, f.createErr
	}
	f.mu.Lock()
	f.created = roomID
	f.mu.Unlock()
	f.info.RoomID = roomID
	return f.info, nil
}

func (f *fakeSession) createdRoom() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.created
}

func (f *fakeSession) Join(_ context.Context, roomID, _ string) (*relay.Info, error) {
	if f.joinErr != nil {
		return nil, f.joinErr
	}
	f.info.RoomID = roomID
	return f.info, nil
}

func (f *fakeSession) Send(_ context.Context, text string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, text)
	return "9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846", nil
}

func (f *fakeSession) sentMessages() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.sent...)
}

func (f *fakeSession) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

func (f *fakeSession) Who(context.Context) ([]relay.Participant, error) {
	if f.whoErr != nil {
		return nil, f.whoErr
	}
	return f.info.Participants, nil
}

func (f *fakeSession) Events() <-chan relay.Event { return f.events }

func (f *fakeSession) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil
	}
	f.closed = true
	close(f.events)
	return nil
}

func info() *relay.Info {
	return &relay.Info{
		RoomID:       "amber-river-copper-moon-forest-glass-harbor-star",
		SenderID:     "u3Bk9QzR2mXvLp7TnAeYwQ",
		Username:     "quiet-otter-42",
		ExpiresAt:    "2026-08-25T14:03:11.000Z",
		Participants: []relay.Participant{{SenderID: "u3Bk9QzR2mXvLp7TnAeYwQ", Username: "quiet-otter-42"}},
	}
}

func config(session tui.Session, joining bool) tui.Config {
	return tui.Config{
		Server:    "ws://127.0.0.1:4000/v1/ws",
		Joining:   joining,
		RoomID:    map[bool]string{true: "amber-river-copper-moon-forest-glass-harbor-star", false: ""}[joining],
		Dial:      func(context.Context, string) (tui.Session, error) { return session, nil },
		Generate:  func() (string, error) { return suggested, nil },
		NewRoomID: func() (string, error) { return "amber-river-copper-moon-forest-glass-harbor-star", nil },
	}
}

// ---------------------------------------------------------------------------
// Driving helpers. Most tests drive Update directly rather than a Program:
// teatest polls rendered frames with timeouts, which is right for whole flows and
// needlessly slow for "does an unknown command get sent".
// ---------------------------------------------------------------------------

func step(m tea.Model, msg tea.Msg) (tea.Model, tea.Cmd) { return m.Update(msg) }

func typeText(m tea.Model, text string) tea.Model {
	for _, r := range text {
		m, _ = step(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	return m
}

func enter(m tea.Model) (tea.Model, tea.Cmd) { return step(m, tea.KeyMsg{Type: tea.KeyEnter}) }

// run executes a Cmd with a deadline, returning nil if it blocks (waitForEvent on
// an idle channel legitimately does).
func run(cmd tea.Cmd) tea.Msg {
	if cmd == nil {
		return nil
	}
	done := make(chan tea.Msg, 1)
	go func() { done <- cmd() }()
	select {
	case msg := <-done:
		return msg
	case <-time.After(2 * time.Second):
		return nil
	}
}

// connected drives a model into the chat phase and returns the event-pump Cmd.
//
// Returning the Cmd is what lets these tests deliver relay events through the
// exact path production uses — waitForEvent receives from the channel and hands
// the model a message — rather than reaching inside the package to construct one.
func connected(t *testing.T, session *fakeSession, joining bool) (tea.Model, tea.Cmd) {
	t.Helper()

	m := tea.Model(tui.New(config(session, joining)))

	var cmd tea.Cmd
	if joining {
		m = typeText(m, "correct-horse-battery")
		m, cmd = enter(m)
	} else {
		m, _ = enter(m)   // accept the suggested passphrase
		m, cmd = enter(m) // confirm it was copied — this is the one that connects
	}

	msg := run(cmd)
	if msg == nil {
		t.Fatal("connecting produced no message")
	}

	m, pumpCmd := step(m, msg)
	if !strings.Contains(m.View(), "Joined as") {
		t.Fatalf("expected the chat view, got:\n%s", m.View())
	}
	return m, pumpCmd
}

// ---------------------------------------------------------------------------

func TestCreateFlowEnterAcceptsTheSuggestedPassphrase(t *testing.T) {
	session := newFakeSession(info())
	m := tea.Model(tui.New(config(session, false)))

	view := m.View()
	if !strings.Contains(view, suggested) {
		t.Errorf("the suggested passphrase must be visible before it can be accepted:\n%s", view)
	}
	// A5 inverts the prompt so the strong path is the lazy one.
	if !strings.Contains(view, "Press Enter to generate a strong passphrase, or type your own") {
		t.Errorf("A5's inverted prompt is missing:\n%s", view)
	}

	m, _ = enter(m)

	// §9.2: a generated password is shown once and the user confirms they copied it.
	view = m.View()
	if !strings.Contains(view, suggested) || !strings.Contains(view, "shown once") {
		t.Errorf("expected the copied-it confirmation, got:\n%s", view)
	}

	m, cmd := enter(m)
	m, _ = step(m, run(cmd))

	if !strings.Contains(m.View(), "Joined as quiet-otter-42") {
		t.Errorf("expected to be in the room, got:\n%s", m.View())
	}
}

func TestCreateFlowTypedPasswordRequiresAMatchingRetype(t *testing.T) {
	session := newFakeSession(info())
	m := tea.Model(tui.New(config(session, false)))

	m = typeText(m, "my-own-password-here")
	m, _ = enter(m)

	if !strings.Contains(m.View(), "Type it again") {
		t.Fatalf("a typed password must be confirmed by retyping (§6.1 step 5), got:\n%s", m.View())
	}

	// A mismatch re-prompts rather than failing out.
	m = typeText(m, "my-own-password-typo")
	m, _ = enter(m)

	view := m.View()
	if !strings.Contains(view, "did not match") {
		t.Errorf("a mismatch must say so, got:\n%s", view)
	}
	if !strings.Contains(view, "or type your own") {
		t.Errorf("a mismatch must return to the password prompt, got:\n%s", view)
	}

	// Getting it right the second time proceeds.
	m = typeText(m, "my-own-password-here")
	m, _ = enter(m)
	m = typeText(m, "my-own-password-here")
	m, cmd := enter(m)
	m, _ = step(m, run(cmd))

	if !strings.Contains(m.View(), "Joined as") {
		t.Errorf("a matching retype should connect, got:\n%s", m.View())
	}
}

func TestPasswordPromptsNeverEcho(t *testing.T) {
	for _, joining := range []bool{false, true} {
		session := newFakeSession(info())
		m := tea.Model(tui.New(config(session, joining)))

		secret := "unmistakable-secret-value"
		m = typeText(m, secret)

		if strings.Contains(m.View(), secret) {
			t.Errorf("joining=%v: the password prompt echoed the password:\n%s", joining, m.View())
		}
	}
}

func TestJoinFlowRendersTheSessionSummary(t *testing.T) {
	session := newFakeSession(info())
	session.info.History = []relay.Message{
		{MessageID: "a", SenderUsername: "bright-fox-17", Sequence: 1, ReceivedAt: "2026-08-20T14:02:10.000Z", Text: "hey"},
		{MessageID: "b", SenderUsername: "quiet-otter-42", Sequence: 2, ReceivedAt: "2026-08-20T14:02:44.000Z", Text: "hello"},
	}

	m, _ := connected(t, session, true)
	view := m.View()

	// Spec §6.2's console transcript.
	for _, want := range []string{"Joined as quiet-otter-42", "Loaded 2 retained messages.", "14:02", "bright-fox-17", "hey"} {
		if !strings.Contains(view, want) {
			t.Errorf("view is missing %q:\n%s", want, view)
		}
	}
}

func TestPlainTextIsSentAndCommandsAreNot(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)

	m = typeText(m, "hello everyone")
	m, cmd := enter(m)
	run(cmd)

	if got := session.sentMessages(); len(got) != 1 || got[0] != "hello everyone" {
		t.Fatalf("plain text should be sent, got %v", got)
	}

	// Spec §6.3: an unknown command is a LOCAL error and is never sent — a typo
	// must not become a public message.
	m = typeText(m, "/wat is this")
	m, cmd = enter(m)
	run(cmd)

	if got := session.sentMessages(); len(got) != 1 {
		t.Errorf("an unknown command must not be sent, got %v", got)
	}
	if !strings.Contains(m.View(), "Unknown command /wat") {
		t.Errorf("expected a local error, got:\n%s", m.View())
	}
}

func TestSupportedCommands(t *testing.T) {
	t.Run("/help lists the commands and the honesty notice", func(t *testing.T) {
		session := newFakeSession(info())
		m, _ := connected(t, session, false)

		m = typeText(m, "/help")
		m, _ = enter(m)

		view := m.View()
		// PgUp/PgDn is in here because /help is currently the only place a user can
		// find out the transcript scrolls at all. ROJ-47 gives it a better home.
		for _, want := range []string{"/help", "/who", "/room", "/quit", "PgUp", "not end-to-end encrypted"} {
			if !strings.Contains(view, want) {
				t.Errorf("/help is missing %q:\n%s", want, view)
			}
		}
	})

	t.Run("/who lists the room", func(t *testing.T) {
		session := newFakeSession(info())
		session.info.Participants = []relay.Participant{
			{SenderID: "u3Bk9QzR2mXvLp7TnAeYwQ", Username: "quiet-otter-42"},
			{SenderID: "Kd8vN2pQ7rT4xW9yZa3bLc", Username: "bright-fox-17"},
		}
		m, _ := connected(t, session, false)

		m = typeText(m, "/who")
		m, cmd := enter(m)
		m, _ = step(m, run(cmd))

		if !strings.Contains(m.View(), "quiet-otter-42") || !strings.Contains(m.View(), "bright-fox-17") {
			t.Errorf("/who should list both usernames:\n%s", m.View())
		}
	})

	t.Run("/quit closes the session and exits 0", func(t *testing.T) {
		session := newFakeSession(info())
		m, _ := connected(t, session, false)

		m = typeText(m, "/quit")
		m, cmd := enter(m)
		run(cmd)

		if !session.isClosed() {
			t.Error("/quit must close the session")
		}
		if code := m.(tui.Model).Outcome().ExitCode(); code != 0 {
			t.Errorf("/quit exit code = %d, want 0", code)
		}
	})
}

func TestCtrlCSemantics(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)

	// Spec §6.3: the first Ctrl+C behaves as /quit.
	m, cmd := step(m, tea.KeyMsg{Type: tea.KeyCtrlC})
	run(cmd)

	if !session.isClosed() {
		t.Error("the first Ctrl+C must close the session cleanly")
	}
	if !strings.Contains(m.View(), "Leaving") {
		t.Errorf("the first Ctrl+C should say what it is doing:\n%s", m.View())
	}
	if code := m.(tui.Model).Outcome().ExitCode(); code != 0 {
		t.Errorf("a clean Ctrl+C exit = %d, want 0", code)
	}

	// A second Ctrl+C terminates immediately, without waiting on anything.
	m, cmd = step(m, tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Fatal("the second Ctrl+C must quit")
	}
}

func TestRelayEventsRender(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)

	events := []relay.Event{
		{Kind: relay.EventPresence, Presence: relay.Presence{Action: "joined", Username: "bright-fox-17", ParticipantCount: 2}},
		{Kind: relay.EventMessage, Message: relay.Message{
			SenderUsername: "bright-fox-17", Sequence: 1,
			ReceivedAt: "2026-08-20T14:07:52.418Z", Text: "hey, does the relay see any of this?",
		}},
		{Kind: relay.EventPresence, Presence: relay.Presence{Action: "left", Username: "bright-fox-17", ParticipantCount: 1}},
	}

	for _, event := range events {
		m, pumpCmd = pump(t, m, pumpCmd, session, event)
	}

	view := m.View()
	for _, want := range []string{"bright-fox-17 joined.", "14:07", "does the relay see any of this?", "bright-fox-17 left."} {
		if !strings.Contains(view, want) {
			t.Errorf("view is missing %q:\n%s", want, view)
		}
	}
	if !strings.Contains(view, "1 online") {
		t.Errorf("the status bar should track the participant count:\n%s", view)
	}
}

func TestRoomExpiryRendersANoticeAndExitsFour(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)

	m, _ = pump(t, m, pumpCmd, session, relay.Event{
		Kind: relay.EventRoomExpired, RoomID: "amber-river-copper-moon-forest-glass-harbor-star",
		At: "2026-08-25T14:03:11.000Z",
	})

	if !strings.Contains(m.View(), "expired") {
		t.Errorf("expiry should be announced:\n%s", m.View())
	}
	if code := m.(tui.Model).Outcome().ExitCode(); code != 4 {
		t.Errorf("room expiry exit code = %d, want 4", code)
	}
}

func TestDisconnectExitsThree(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)

	m, _ = pump(t, m, pumpCmd, session,
		relay.Event{Kind: relay.EventDisconnect, Reason: "relay closed the connection (1006)"})

	if code := m.(tui.Model).Outcome().ExitCode(); code != 3 {
		t.Errorf("disconnect exit code = %d, want 3", code)
	}
}

func TestFailedJoinMapsToTheSpecExitCode(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"wrong password", &relay.Error{Code: protocol.CodeAuthenticationFailed, Message: "authentication failed"}, 5},
		{"unknown room", &relay.Error{Code: protocol.CodeRoomNotFound, Message: "room not found"}, 4},
		{"transport", errors.New("connection refused"), 3},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			session := newFakeSession(info())
			session.joinErr = tc.err

			m := tea.Model(tui.New(config(session, true)))
			m = typeText(m, "correct-horse-battery")
			m, cmd := enter(m)
			m, _ = step(m, run(cmd))

			if code := m.(tui.Model).Outcome().ExitCode(); code != tc.want {
				t.Errorf("exit code = %d, want %d", code, tc.want)
			}
		})
	}
}

func TestUnicodeRenders(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)

	samples := []string{"🦊 skulk 潜行", "مرحبا 🌍", "ここにいます"}
	for i, text := range samples {
		m, pumpCmd = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
			SenderUsername: "bright-fox-17", Sequence: i + 1,
			ReceivedAt: "2026-08-20T14:07:52.418Z", Text: text,
		}})
	}

	view := m.View()
	for _, text := range samples {
		if !strings.Contains(view, text) {
			t.Errorf("view is missing %q:\n%s", text, view)
		}
	}
}

// pump delivers one relay event through the production Cmd path and returns the
// re-armed pump, exactly as the running program does.
func pump(t *testing.T, m tea.Model, cmd tea.Cmd, session *fakeSession, event relay.Event) (tea.Model, tea.Cmd) {
	t.Helper()

	session.events <- event
	msg := run(cmd)
	if msg == nil {
		t.Fatal("the event pump produced nothing")
	}
	return step(m, msg)
}

// ---------------------------------------------------------------------------
// teatest — bubbletea's own harness, for the two things that only make sense
// against a running Program: a whole flow driven by keystrokes, and a resize.
//
// The rest of this file drives Update directly. teatest polls rendered frames
// with timeouts, which is right for end-to-end behaviour and needlessly slow for
// "is an unknown command sent".
// ---------------------------------------------------------------------------

func TestCreateFlowThroughARunningProgram(t *testing.T) {
	session := newFakeSession(info())
	model := tui.New(config(session, false))

	tm := teatest.NewTestModel(t, model, teatest.WithInitialTermSize(100, 30))

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte(suggested))
	}, teatest.WithDuration(5*time.Second))

	tm.Send(tea.KeyMsg{Type: tea.KeyEnter}) // accept the suggestion
	tm.Send(tea.KeyMsg{Type: tea.KeyEnter}) // confirm it was copied

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("Joined as quiet-otter-42"))
	}, teatest.WithDuration(5*time.Second))

	// A real keystroke path all the way to a sent message.
	for _, r := range "hello from a real program" {
		tm.Send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	tm.Send(tea.KeyMsg{Type: tea.KeyEnter})

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return len(session.sentMessages()) == 1
	}, teatest.WithDuration(5*time.Second))

	tm.Send(tea.KeyMsg{Type: tea.KeyCtrlC})
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))

	if got := session.sentMessages(); len(got) != 1 || got[0] != "hello from a real program" {
		t.Errorf("sent = %v", got)
	}
}

func TestResizeDoesNotGarbleTheTranscript(t *testing.T) {
	session := newFakeSession(info())
	session.info.History = []relay.Message{
		{SenderUsername: "bright-fox-17", Sequence: 1, ReceivedAt: "2026-08-20T14:02:10.000Z", Text: "a message that should survive a resize"},
	}
	model := tui.New(config(session, false))

	tm := teatest.NewTestModel(t, model, teatest.WithInitialTermSize(100, 30))
	tm.Send(tea.KeyMsg{Type: tea.KeyEnter})
	tm.Send(tea.KeyMsg{Type: tea.KeyEnter})

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("survive a resize"))
	}, teatest.WithDuration(5*time.Second))

	// Shrink hard, then grow: a transcript that indexes badly on height crashes here.
	for _, size := range [][2]int{{40, 10}, {200, 60}, {80, 6}, {120, 40}} {
		tm.Send(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
	}

	teatest.WaitFor(t, tm.Output(), func(out []byte) bool {
		return bytes.Contains(out, []byte("survive a resize"))
	}, teatest.WithDuration(5*time.Second))

	tm.Send(tea.KeyMsg{Type: tea.KeyCtrlC})
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))
}

// ---------------------------------------------------------------------------
// Transcript wrapping — regression tests for a reported bug: long messages were
// cut off at the terminal edge rather than wrapped, because the model stored a
// pre-formatted line per message and never consulted the width it was told about.
// ---------------------------------------------------------------------------

const longMessage = "This is the kind of answer an assistant gives: it runs well past eighty " +
	"columns without a single newline in it, and it keeps going for quite a while longer still, " +
	"which is exactly the case that used to disappear off the right-hand edge of the terminal."

func rendered(t *testing.T, m tea.Model) []string {
	t.Helper()
	return strings.Split(strings.TrimRight(m.View(), "\n"), "\n")
}

func widest(lines []string) (int, string) {
	worst, at := 0, ""
	for _, line := range lines {
		if w := lipgloss.Width(line); w > worst {
			worst, at = w, line
		}
	}
	return worst, at
}

func TestLongMessagesWrapToTheTerminalWidth(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 80, Height: 24})

	m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 1,
		ReceivedAt: "2026-08-20T14:07:52.418Z", Text: longMessage,
	}})

	lines := rendered(t, m)
	if w, at := widest(lines); w > 80 {
		t.Errorf("a line is %d columns wide in an 80-column terminal:\n%q", w, at)
	}

	// Wrapped, not truncated: the tail must still be on screen somewhere.
	if !strings.Contains(strings.Join(lines, " "), "right-hand edge of the terminal") {
		t.Errorf("the end of the message was lost:\n%s", m.View())
	}
}

// Continuation lines hang under the message body, not under the timestamp, so a
// wrapped message still reads as one message.
func TestWrappedMessagesHangUnderTheirBody(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 80, Height: 40})

	m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 1,
		ReceivedAt: "2026-08-20T14:07:52.418Z", Text: longMessage,
	}})

	lines := rendered(t, m)
	var first, second string
	for i, line := range lines {
		if strings.Contains(line, "14:07") {
			first = line
			if i+1 < len(lines) {
				second = lines[i+1]
			}
			break
		}
	}
	if first == "" || second == "" {
		t.Fatalf("expected a wrapped message:\n%s", m.View())
	}

	indent := strings.Index(first, "This is the kind")
	if indent <= 0 {
		t.Fatalf("could not locate the message body in %q", first)
	}
	if got := len(second) - len(strings.TrimLeft(second, " ")); got != indent {
		t.Errorf("continuation indent = %d, want %d (aligned under the body)\n  %q\n  %q",
			got, indent, first, second)
	}
}

// Re-wrapping on resize is why entries are stored unwrapped: a line wrapped when it
// arrived would stay wrapped to the old width forever.
func TestTranscriptRewrapsOnResize(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 120, Height: 40})

	m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 1,
		ReceivedAt: "2026-08-20T14:07:52.418Z", Text: longMessage,
	}})

	for _, width := range []int{120, 100, 80, 60, 40, 30} {
		m, _ = step(m, tea.WindowSizeMsg{Width: width, Height: 40})
		if w, at := widest(rendered(t, m)); w > width {
			t.Errorf("at width %d a line is %d columns:\n%q", width, w, at)
		}
	}
}

// Wide characters are two columns each, so a rune count is the wrong measure.
func TestWideCharactersWrapByColumnNotRuneCount(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 60, Height: 30})

	m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 1,
		ReceivedAt: "2026-08-20T14:07:52.418Z",
		Text:       strings.Repeat("潜行する狐は静かに動く", 8),
	}})

	if w, at := widest(rendered(t, m)); w > 60 {
		t.Errorf("wide-character line is %d columns in a 60-column terminal:\n%q", w, at)
	}
}

// The input line must survive a transcript full of wrapped messages — the height
// arithmetic has to count rendered rows, not messages.
func TestInputStaysOnScreenWhenMessagesWrap(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 60, Height: 12})

	for i := 1; i <= 10; i++ {
		m, pumpCmd = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
			SenderUsername: "bright-fox-17", Sequence: i,
			ReceivedAt: "2026-08-20T14:07:52.418Z", Text: longMessage,
		}})
	}

	lines := rendered(t, m)
	if len(lines) > 12 {
		t.Errorf("rendered %d rows into a 12-row terminal", len(lines))
	}
	// ROJ-49 put the input in a box, so the prompt is the middle of the last three
	// rows rather than the last one. Still the same property: it survives.
	if !strings.Contains(inputRow(t, m), ">") {
		t.Errorf("the input prompt was pushed off screen; last rows are %q", lines[len(lines)-3:])
	}
}

// The status bar is the third place the width bug lived: an eight-word room id is
// ~48 columns on its own, so a narrow terminal overflowed there too. Found by the
// resize test above rather than by inspection.
func TestStatusBarFitsNarrowTerminals(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)

	for _, width := range []int{120, 80, 60, 40, 30, 20, 12} {
		m, _ = step(m, tea.WindowSizeMsg{Width: width, Height: 20})

		status := rendered(t, m)[0]
		if w := lipgloss.Width(status); w > width {
			t.Errorf("status bar is %d columns in a %d-column terminal: %q", w, width, status)
		}
		// The word "online" is droppable on a tiny terminal; the count is not,
		// because "am I alone in here?" is what the bar is for.
		if !strings.Contains(status, "1") {
			t.Errorf("at width %d the participant count was lost: %q", width, status)
		}
	}
}

// Eliding keeps both ends, so a human can still tell which room they are in.
func TestStatusBarElisionKeepsBothEndsOfTheRoomID(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 44, Height: 20})

	status := rendered(t, m)[0]
	if !strings.HasPrefix(status, "amber-") {
		t.Errorf("elided id lost its head: %q", status)
	}
	if !strings.Contains(status, "-star") {
		t.Errorf("elided id lost its tail: %q", status)
	}
	if !strings.Contains(status, "…") {
		t.Errorf("elision should be visible: %q", status)
	}
}

// ---------------------------------------------------------------------------
// Full-screen chat (ROJ-46). The transcript used to be a hand-sliced "last N
// rows", which meant anything older than one screen was gone for good. It is now
// a viewport, and these tests pin the two properties that make it worth having:
// it scrolls, and it does not yank you back to the bottom while you are reading.
//
// The scroll position is not observable from outside the package, so every
// assertion here is made against rendered content. That is the honest test
// anyway: what the user can see is the whole feature.
// ---------------------------------------------------------------------------

// marker returns the body of the n-th filler message. Zero-padded so that
// "marker-30" is never a substring of another marker.
func marker(n int) string { return fmt.Sprintf("marker-%02d", n) }

// filled drives a model into chat at a known size and pushes enough short
// messages that the transcript is several screens tall.
func filled(t *testing.T, width, height, count int) (tea.Model, tea.Cmd, *fakeSession) {
	t.Helper()

	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: width, Height: height})

	for i := 1; i <= count; i++ {
		m, pumpCmd = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
			SenderUsername: "bright-fox-17", Sequence: i,
			ReceivedAt: "2026-08-20T14:07:52.418Z", Text: marker(i),
		}})
	}
	return m, pumpCmd, session
}

// The alt-screen half of the ticket: the program takes over the display and gives
// the terminal back on exit, the way vim and htop do.
//
// This drives a real tea.Program rather than teatest, because alt-screen is a
// program option and teatest builds its own Program with no way to pass one
// through. tui.NewProgram is the single place that option lives, so running it
// here tests exactly what cmd/skulk runs.
func TestTheProgramRunsFullScreenAndRestoresTheTerminal(t *testing.T) {
	session := newFakeSession(info())
	out := &lockedBuffer{}

	program := tui.NewProgram(tui.New(config(session, false)),
		tea.WithInput(&bytes.Buffer{}), tea.WithOutput(out), tea.WithoutSignals())

	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := program.Run(); err != nil {
			t.Errorf("program failed: %v", err)
		}
	}()

	program.Send(tea.WindowSizeMsg{Width: 100, Height: 30})

	// \x1b[?1049h switches the terminal to its alternate screen buffer.
	waitForOutput(t, out, "\x1b[?1049h")

	program.Send(tea.KeyMsg{Type: tea.KeyEnter}) // accept the suggestion
	program.Send(tea.KeyMsg{Type: tea.KeyEnter}) // confirm it was copied
	waitForOutput(t, out, "Joined as quiet-otter-42")

	program.Send(tea.KeyMsg{Type: tea.KeyCtrlC})
	<-done

	// \x1b[?1049l restores the buffer that was there before skulk started, which
	// is the half of "full-screen" a user only notices when it is missing.
	if !strings.Contains(out.String(), "\x1b[?1049l") {
		t.Error("the program did not restore the terminal's previous contents on exit")
	}
}

// PgUp reaches messages that scrolled off the top; PgDn comes back.
func TestTheTranscriptScrollsBeyondOneScreen(t *testing.T) {
	m, _, _ := filled(t, 80, 14, 30)

	if view := m.View(); !strings.Contains(view, marker(30)) {
		t.Fatalf("the newest message should be on screen:\n%s", view)
	}
	if view := m.View(); strings.Contains(view, marker(1)) {
		t.Fatalf("30 messages cannot fit in a 14-row terminal; the view is not clipping:\n%s", view)
	}

	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgUp})

	view := m.View()
	if strings.Contains(view, marker(30)) {
		t.Errorf("PgUp did not move the view:\n%s", view)
	}
	if !strings.Contains(view, marker(20)) {
		t.Errorf("PgUp should reveal older messages:\n%s", view)
	}

	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgDown})

	if view := m.View(); !strings.Contains(view, marker(30)) {
		t.Errorf("PgDn should return to the newest messages:\n%s", view)
	}
}

// Auto-follow: sitting at the bottom, a new message appears without a keystroke.
func TestNewMessagesAutoFollowWhenTheViewIsAtTheBottom(t *testing.T) {
	m, pumpCmd, session := filled(t, 80, 14, 30)

	m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 31,
		ReceivedAt: "2026-08-20T14:09:00.000Z", Text: "the-newest-thing",
	}})

	if view := m.View(); !strings.Contains(view, "the-newest-thing") {
		t.Errorf("a message that arrives while the view is at the bottom must be visible:\n%s", view)
	}
}

// The one that matters: a client that yanks you to the bottom mid-sentence is
// worse than one that cannot scroll at all.
func TestNewMessagesDoNotYankTheViewWhenScrolledUp(t *testing.T) {
	m, pumpCmd, session := filled(t, 80, 14, 30)

	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgUp})
	before := m.View()

	m, pumpCmd = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 31,
		ReceivedAt: "2026-08-20T14:09:00.000Z", Text: "arrived-while-reading",
	}})

	if view := m.View(); strings.Contains(view, "arrived-while-reading") {
		t.Errorf("a new message yanked the view back to the bottom:\n%s", view)
	}
	if view := m.View(); view != before {
		t.Errorf("the view moved under the reader:\nbefore:\n%s\nafter:\n%s", before, view)
	}

	// And it is still there once the reader chooses to come back. Two presses,
	// because paging down is exactly that — a page at a time — and the transcript
	// grew by a row while it was being read.
	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgDown})
	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgDown})

	if view := m.View(); !strings.Contains(view, "arrived-while-reading") {
		t.Errorf("PgDn should catch up with what arrived while scrolled up:\n%s", view)
	}

	// Following resumes: the next message needs no keystroke.
	m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventMessage, Message: relay.Message{
		SenderUsername: "bright-fox-17", Sequence: 32,
		ReceivedAt: "2026-08-20T14:09:30.000Z", Text: "following-again",
	}})

	if view := m.View(); !strings.Contains(view, "following-again") {
		t.Errorf("returning to the bottom should resume auto-follow:\n%s", view)
	}
}

// Key routing has to be right in both directions, and each direction has its own
// way of going wrong.
//
// bubbles' viewport binds f, b, u, d, j, k, h, l and space by default, so handing
// it a KeyMsg would make typing those letters scroll the transcript. Forwarding
// PgUp to the input types into the message box instead. The text below is exactly
// the bound letters, typed while scrolled up so that any scrolling shows.
func TestKeyRoutingKeepsScrollingAndTypingApart(t *testing.T) {
	m, _, session := filled(t, 80, 14, 30)

	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgUp})
	if view := m.View(); !strings.Contains(view, marker(20)) {
		t.Fatalf("expected to be scrolled up:\n%s", view)
	}

	m = typeText(m, "fudbjk hl")

	view := m.View()
	if !strings.Contains(view, marker(20)) || strings.Contains(view, marker(30)) {
		t.Errorf("typing scrolled the transcript:\n%s", view)
	}

	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgDown})
	m = typeText(m, " and a space")

	m, cmd := enter(m)
	run(cmd)

	if got := session.sentMessages(); len(got) != 1 || got[0] != "fudbjk hl and a space" {
		t.Errorf("scroll keys leaked into the message: %q", got)
	}
}

// Typing while scrolled up works, and sending returns the view to the live edge —
// you acted, so you want to see what happened.
func TestSendingWhileScrolledUpJumpsBackToTheLatest(t *testing.T) {
	m, _, session := filled(t, 80, 14, 30)

	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgUp})
	if view := m.View(); strings.Contains(view, marker(30)) {
		t.Fatalf("expected to be scrolled up:\n%s", view)
	}

	m = typeText(m, "typed while reading history")
	m, cmd := enter(m)
	run(cmd)

	if got := session.sentMessages(); len(got) != 1 || got[0] != "typed while reading history" {
		t.Errorf("typing while scrolled up should still send: %q", got)
	}
	if view := m.View(); !strings.Contains(view, marker(30)) {
		t.Errorf("sending should return the view to the live edge:\n%s", view)
	}
}

// A model that never received a WindowSizeMsg still has to render: most tests in
// this file drive Update directly and never send one, and a viewport of height
// zero shows nothing at all.
func TestAModelNeverToldTheTerminalSizeStillRenders(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)

	lines := rendered(t, m)
	if len(lines) < 5 {
		t.Fatalf("a default-sized model rendered %d rows:\n%s", len(lines), m.View())
	}
	if !strings.Contains(m.View(), "Joined as quiet-otter-42") {
		t.Errorf("the transcript is empty at the default size:\n%s", m.View())
	}
	if !strings.Contains(inputRow(t, m), ">") {
		t.Errorf("the input prompt is missing; last rows are %q", lines[len(lines)-3:])
	}
}

// A full-screen app owns exactly the rows it was given. One row too many and the
// terminal scrolls, which in alt-screen mode looks like the app tearing itself.
func TestTheChatFrameIsExactlyTheTerminalHeight(t *testing.T) {
	// Below six rows there is nowhere to put a status bar, a transcript and a
	// three-row input box, so the frame keeps its minimum and the terminal is on
	// its own. That floor moved from five when ROJ-49 boxed the input.
	for _, size := range [][2]int{{80, 24}, {40, 10}, {120, 60}, {80, 7}, {100, 6}} {
		m, _, _ := filled(t, size[0], size[1], 30)

		if lines := rendered(t, m); len(lines) != size[1] {
			t.Errorf("%dx%d rendered %d rows", size[0], size[1], len(lines))
		}
	}
}

// Resizing while scrolled up must not leave the offset pointing past the end of
// a transcript that just got shorter in rows.
func TestResizingWhileScrolledUpStaysInsideTheTranscript(t *testing.T) {
	m, _, _ := filled(t, 60, 14, 30)
	m, _ = step(m, tea.KeyMsg{Type: tea.KeyPgUp})

	for _, size := range [][2]int{{200, 60}, {40, 8}, {120, 40}, {80, 6}} {
		m, _ = step(m, tea.WindowSizeMsg{Width: size[0], Height: size[1]})

		lines := rendered(t, m)
		if len(lines) != size[1] {
			t.Fatalf("%dx%d rendered %d rows", size[0], size[1], len(lines))
		}
		if w, at := widest(lines); w > size[0] {
			t.Errorf("at width %d a line is %d columns:\n%q", size[0], w, at)
		}
	}
}

// Closing the socket makes the relay's read loop fail, which emits a disconnect
// and closes the event channel. That is the shutdown completing, not the relay
// dropping us — and acting on it would turn a clean /quit into exit 3 with a
// "disconnected" line printed to stderr.
func TestACleanQuitIsNotReportedAsADisconnect(t *testing.T) {
	session := newFakeSession(info())
	m, pumpCmd := connected(t, session, false)

	// Queued before the quit, because closing the session closes the channel —
	// which is the ordering production has: Close makes the read loop fail, the
	// failure emits this event, and the channel closes behind it.
	session.events <- relay.Event{Kind: relay.EventDisconnect, Reason: "relay closed the connection (1000)"}

	m = typeText(m, "/quit")
	m, cmd := enter(m)
	run(cmd)

	m, _ = step(m, run(pumpCmd))

	if code := m.(tui.Model).Outcome().ExitCode(); code != 0 {
		t.Errorf("a clean /quit exited %d, want 0", code)
	}
	if reason := m.(tui.Model).Reason(); reason != "" {
		t.Errorf("a clean /quit reported %q", reason)
	}
}

// Alt-screen restores the terminal on exit, which takes the final frame with it.
// Anything the user needs to read after skulk stops has to leave through Reason
// so cmd/skulk can print it to stderr.
func TestFatalOutcomesCarryAReasonOutOfTheAltScreen(t *testing.T) {
	t.Run("disconnect", func(t *testing.T) {
		session := newFakeSession(info())
		m, pumpCmd := connected(t, session, false)

		m, _ = pump(t, m, pumpCmd, session,
			relay.Event{Kind: relay.EventDisconnect, Reason: "relay closed the connection (1006)"})

		if reason := m.(tui.Model).Reason(); !strings.Contains(reason, "1006") {
			t.Errorf("Reason() = %q, want the disconnect reason", reason)
		}
	})

	t.Run("room expired", func(t *testing.T) {
		session := newFakeSession(info())
		m, pumpCmd := connected(t, session, false)

		m, _ = pump(t, m, pumpCmd, session, relay.Event{Kind: relay.EventRoomExpired})

		if reason := m.(tui.Model).Reason(); !strings.Contains(reason, "expired") {
			t.Errorf("Reason() = %q, want the expiry reason", reason)
		}
	})

	t.Run("a clean exit has nothing to say", func(t *testing.T) {
		session := newFakeSession(info())
		m, _ := connected(t, session, false)

		m = typeText(m, "/quit")
		m, cmd := enter(m)
		run(cmd)

		if reason := m.(tui.Model).Reason(); reason != "" {
			t.Errorf("Reason() = %q, want empty", reason)
		}
	})

	// The prompt shares one err field with the session, and getting a password
	// wrong before getting it right left the rejection sitting in it. Nothing saw
	// that until Reason() started printing to stderr: a clean exit after a typo
	// would exit 0 and complain about a password that was later accepted.
	t.Run("a rejected password does not outlive the prompt", func(t *testing.T) {
		session := newFakeSession(info())
		m := tea.Model(tui.New(config(session, true)))

		m = typeText(m, "short")
		m, _ = enter(m)
		if !strings.Contains(m.View(), "at least") {
			t.Fatalf("expected the password to be rejected:\n%s", m.View())
		}

		m = typeText(m, "correct-horse-battery")
		m, cmd := enter(m)
		m, _ = step(m, run(cmd))

		if !strings.Contains(m.View(), "Joined as") {
			t.Fatalf("expected to be connected:\n%s", m.View())
		}
		if reason := m.(tui.Model).Reason(); reason != "" {
			t.Errorf("a password error survived a successful connection: %q", reason)
		}

		// It must not be the final frame either: phaseDone renders err in place of
		// the transcript, so a stale one replaces the whole session.
		m = typeText(m, "/quit")
		m, cmd = enter(m)
		run(cmd)

		if view := m.View(); strings.Contains(view, "at least") {
			t.Errorf("a stale password error replaced the final frame:\n%s", view)
		}
	})

	// Aborting at a prompt with an error on screen is not a failure: the user read
	// it and chose to leave. Reason() is why the session ENDED, and Ctrl+C is.
	t.Run("aborting at a prompt is not a reason", func(t *testing.T) {
		session := newFakeSession(info())
		m := tea.Model(tui.New(config(session, true)))

		m = typeText(m, "short")
		m, _ = enter(m)
		m, cmd := step(m, tea.KeyMsg{Type: tea.KeyCtrlC})
		run(cmd)

		if code := m.(tui.Model).Outcome().ExitCode(); code != 0 {
			t.Errorf("aborting at a prompt exited %d, want 0", code)
		}
		if reason := m.(tui.Model).Reason(); reason != "" {
			t.Errorf("aborting at a prompt reported %q", reason)
		}
	})
}

// ---------------------------------------------------------------------------

// lockedBuffer is an output the renderer writes from its own goroutine while the
// test reads it. -race finds this without the mutex.
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

func waitForOutput(t *testing.T, out *lockedBuffer, want string) {
	t.Helper()

	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if strings.Contains(out.String(), want) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %q in:\n%q", want, out.String())
}

// ---------------------------------------------------------------------------
// ROJ-49 — feedback from the first real session.
//
// "I created and joined the room but then I have no idea what the room name was
// so I couldn't share it with the other chat."
//
// The status bar had shown the room id all along. The actual defect was that the
// room id and the password were never on screen at the same time: the password is
// displayed once (§9.2), and the room id did not exist until connect() ran, a
// screen later. There was no moment at which a complete invite existed.
// ---------------------------------------------------------------------------

// inputRow is the middle row of the bordered input box — the one with the prompt
// in it. The box is the last three rows of the frame.
func inputRow(t *testing.T, m tea.Model) string {
	t.Helper()

	lines := rendered(t, m)
	if len(lines) < 3 {
		t.Fatalf("frame is only %d rows:\n%s", len(lines), m.View())
	}
	return lines[len(lines)-2]
}

func TestTheDisplayOnceScreenIsACompleteInvite(t *testing.T) {
	session := newFakeSession(info())
	m := tea.Model(tui.New(config(session, false)))

	m, _ = enter(m) // accept the suggested passphrase

	view := m.View()
	if !strings.Contains(view, suggested) {
		t.Errorf("the password must be on the display-once screen:\n%s", view)
	}
	// The half that was missing. Half an invite is no invite.
	if !strings.Contains(view, "amber-river-copper-moon-forest-glass-harbor-star") {
		t.Errorf("the room id must be on the same screen as the password:\n%s", view)
	}
	if !strings.Contains(view, "shown once") {
		t.Errorf("§9.2's display-once warning is missing:\n%s", view)
	}
}

// The room id is generated before the password is displayed, not after — but it
// must still be the id the room is actually created with.
func TestTheRoomIsCreatedWithTheIDThatWasDisplayed(t *testing.T) {
	session := newFakeSession(info())
	m := tea.Model(tui.New(config(session, false)))

	m, _ = enter(m)
	displayed := m.View()

	m, cmd := enter(m)
	m, _ = step(m, run(cmd))

	if !strings.Contains(displayed, session.createdRoom()) {
		t.Errorf("created room %q was not the one displayed:\n%s", session.createdRoom(), displayed)
	}
}

func TestRoomCommandRecallsTheInvite(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, true) // joining: no invite notice on connect

	m = typeText(m, "/room")
	m, _ = enter(m)

	view := m.View()
	if !strings.Contains(view, "amber-river-copper-moon-forest-glass-harbor-star") {
		t.Errorf("/room must show the room id:\n%s", view)
	}
	// The id has to be on a line of its own: an eight-word id plus a relay URL is
	// close to a hundred columns, and a command that wraps cannot be copied.
	if !strings.Contains(view, "    amber-river-copper-moon-forest-glass-harbor-star") {
		t.Errorf("the room id needs its own line to be selectable:\n%s", view)
	}
	if !strings.Contains(view, "skulk join") {
		t.Errorf("/room must say how someone joins:\n%s", view)
	}
	// A room id alone is not something anyone can act on.
	if !strings.Contains(view, "ws://127.0.0.1:4000/v1/ws") {
		t.Errorf("the invite must name the relay:\n%s", view)
	}
}

// §9.2: a generated password is displayed once. Re-showing it on demand would be
// a spec amendment, not a convenience — so this asserts the negative.
func TestRoomCommandNeverRepeatsThePassword(t *testing.T) {
	session := newFakeSession(info())
	m := tea.Model(tui.New(config(session, false)))

	m, _ = enter(m) // accept the suggested passphrase
	m, cmd := enter(m)
	m, _ = step(m, run(cmd))

	m = typeText(m, "/room")
	m, _ = enter(m)

	if view := m.View(); strings.Contains(view, suggested) {
		t.Errorf("/room re-displayed the password, which §9.2 shows exactly once:\n%s", view)
	}
}

// Recall-on-demand and show-at-the-right-moment are different failure modes: the
// user lost the id seconds after seeing it, without knowing a command existed.
func TestCreatingARoomLeavesTheInviteInTheTranscript(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)

	view := m.View()
	if !strings.Contains(view, "    amber-river-copper-moon-forest-glass-harbor-star") {
		t.Errorf("creating a room should leave the room id in the transcript:\n%s", view)
	}
	if !strings.Contains(view, "skulk join") {
		t.Errorf("the transcript should say how someone joins:\n%s", view)
	}

	// Joining a room you were invited to does not need an invite of its own.
	other := newFakeSession(info())
	joined, _ := connected(t, other, true)

	if view := joined.View(); strings.Contains(view, "skulk join") {
		t.Errorf("the join flow should not print an invite:\n%s", view)
	}
}

func TestThePromptCarriesTheAssignedUsername(t *testing.T) {
	session := newFakeSession(info())
	m := tea.Model(tui.New(config(session, false)))

	// The relay assigns the username, so there is nothing to show before it does.
	if view := m.View(); strings.Contains(view, "quiet-otter-42 >") {
		t.Errorf("the password prompt cannot know a username yet:\n%s", view)
	}

	m, _ = enter(m)
	m, cmd := enter(m)
	m, _ = step(m, run(cmd))

	if row := inputRow(t, m); !strings.Contains(row, "quiet-otter-42 >") {
		t.Errorf("the prompt should carry the username, got %q", row)
	}
}

func TestTheInputSitsInABorderedBox(t *testing.T) {
	session := newFakeSession(info())
	m, _ := connected(t, session, false)
	m, _ = step(m, tea.WindowSizeMsg{Width: 80, Height: 24})

	lines := rendered(t, m)
	top, middle, bottom := lines[len(lines)-3], lines[len(lines)-2], lines[len(lines)-1]

	for _, row := range []struct{ line, corner string }{{top, "╭"}, {middle, "│"}, {bottom, "╰"}} {
		if !strings.HasPrefix(row.line, row.corner) {
			t.Errorf("expected a box row starting %q, got %q", row.corner, row.line)
		}
		if w := lipgloss.Width(row.line); w != 80 {
			t.Errorf("box row is %d columns in an 80-column terminal: %q", w, row.line)
		}
	}
	if !strings.Contains(middle, ">") {
		t.Errorf("the prompt should be inside the box, got %q", middle)
	}
}

// lipgloss wraps content to fit a width, so a prompt longer than a narrow box
// would turn three rows into four and break the frame-height guarantee. The text
// has to scroll instead.
func TestANarrowTerminalScrollsTheInputRatherThanGrowingTheBox(t *testing.T) {
	for _, size := range [][2]int{{120, 24}, {80, 24}, {40, 20}, {24, 12}, {20, 10}, {12, 8}} {
		session := newFakeSession(info())
		m, _ := connected(t, session, false)
		m, _ = step(m, tea.WindowSizeMsg{Width: size[0], Height: size[1]})
		m = typeText(m, "a message far longer than any of these terminals are wide")

		lines := rendered(t, m)
		if len(lines) != size[1] {
			t.Errorf("%dx%d rendered %d rows — the box grew", size[0], size[1], len(lines))
		}
		if w, at := widest(lines); w > size[0] {
			t.Errorf("at width %d a line is %d columns: %q", size[0], w, at)
		}
	}
}

// Every prompt in the app is the same composing region. A bare `>` on the
// password screens and a box in the chat read as two different programs.
func TestPasswordPromptsSitInTheSameBox(t *testing.T) {
	for _, joining := range []bool{false, true} {
		session := newFakeSession(info())
		m := tea.Model(tui.New(config(session, joining)))
		m, _ = step(m, tea.WindowSizeMsg{Width: 80, Height: 24})

		if !strings.Contains(m.View(), "╭") || !strings.Contains(m.View(), "╰") {
			t.Errorf("joining=%v: the password prompt is not boxed:\n%s", joining, m.View())
		}
		// §9.2 still holds: a box is not an excuse to echo.
		m = typeText(m, "unmistakable-secret-value")
		if strings.Contains(m.View(), "unmistakable-secret-value") {
			t.Errorf("joining=%v: the boxed prompt echoed the password:\n%s", joining, m.View())
		}
	}
}
