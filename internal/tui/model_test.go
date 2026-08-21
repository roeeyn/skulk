package tui_test

import (
	"bytes"
	"context"
	"errors"
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
	mu     sync.Mutex
	sent   []string
	closed bool
}

func newFakeSession(info *relay.Info) *fakeSession {
	return &fakeSession{events: make(chan relay.Event, 16), info: info}
}

func (f *fakeSession) Create(_ context.Context, roomID, _ string) (*relay.Info, error) {
	if f.createErr != nil {
		return nil, f.createErr
	}
	f.info.RoomID = roomID
	return f.info, nil
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
		for _, want := range []string{"/help", "/who", "/quit", "not end-to-end encrypted"} {
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
	if !strings.Contains(lines[len(lines)-1], ">") {
		t.Errorf("the input prompt was pushed off screen; last row is %q", lines[len(lines)-1])
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
