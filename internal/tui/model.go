// Package tui is skulk's human face: a bubbletea model over the same
// internal/relay session layer the headless mode uses.
//
// The two front ends deliberately share everything below the presentation layer.
// A TUI with its own connection handling would drift from the documented headless
// contract, and the integration suite only exercises one of them.
package tui

import (
	"context"
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/roeeyn/skulk/internal/protocol"
	"github.com/roeeyn/skulk/internal/relay"
)

// Outcome is how the session ended. bubbletea's Quit carries no exit status, so
// the model records the outcome and cmd/skulk maps it to spec §17's table after
// the program returns — nothing here calls os.Exit.
type Outcome int

const (
	OutcomeOK Outcome = iota
	OutcomeFailure
	OutcomeTransport
	OutcomeNoRoom
	OutcomeAuthFailed
	OutcomeCapacity
	OutcomeProtocol
)

// ExitCode maps an outcome to spec §17's process exit codes.
func (o Outcome) ExitCode() int {
	switch o {
	case OutcomeOK:
		return 0
	case OutcomeTransport:
		return 3
	case OutcomeNoRoom:
		return 4
	case OutcomeAuthFailed:
		return 5
	case OutcomeCapacity:
		return 6
	case OutcomeProtocol:
		return 7
	default:
		return 1
	}
}

type phase int

const (
	phaseCreatePassword phase = iota
	phaseConfirmCopied
	phaseRetype
	phaseJoinPassword
	phaseConnecting
	phaseChat
	phaseDone
)

// Config is everything the model needs from the outside world.
type Config struct {
	Server    string
	RoomID    string // empty on create: generated locally
	Joining   bool
	Dial      Dialer
	Generate  Generator
	NewRoomID Generator
}

// Model is the bubbletea model. Update and View are pure with respect to the
// seams in Config, so most tests drive Update directly rather than a Program.
type Model struct {
	cfg Config

	phase   phase
	input   textinput.Model
	width   int
	height  int
	status  string
	outcome Outcome

	suggested  string
	password   string
	firstTyped string

	session  Session
	info     *relay.Info
	events   <-chan relay.Event
	lines    []string
	online   int
	roomID   string
	username string
	senderID string

	quitting bool // a first Ctrl+C has been seen
	err      string
}

// New builds a model for either flow. Nothing connects until the password is in.
func New(cfg Config) Model {
	input := textinput.New()
	input.Prompt = "> "
	input.CharLimit = protocol.MaxTextBytes
	input.Focus()

	m := Model{cfg: cfg, input: input, roomID: cfg.RoomID}

	if cfg.Joining {
		m.phase = phaseJoinPassword
		m.maskInput()
	} else {
		m.phase = phaseCreatePassword
		// A5 inverts the prompt: the generated passphrase is the default and
		// pressing Enter accepts it. Typing your own becomes the deliberate act,
		// which is the whole point — the strong path should be the lazy path.
		if suggested, err := cfg.Generate(); err == nil {
			m.suggested = suggested
		} else {
			m.err = fmt.Sprintf("could not generate a passphrase: %v", err)
		}
		m.maskInput()
	}
	return m
}

// Outcome reports how the session ended, for the caller's exit code.
func (m Model) Outcome() Outcome { return m.outcome }

func (m *Model) maskInput() {
	// Spec §9.2: password prompts never echo.
	m.input.EchoMode = textinput.EchoPassword
	m.input.EchoCharacter = '•'
	m.input.SetValue("")
}

func (m *Model) unmaskInput() {
	m.input.EchoMode = textinput.EchoNormal
	m.input.SetValue("")
}

func (m Model) Init() tea.Cmd { return textinput.Blink }

// --------------------------------------------------------------------------
// Messages
// --------------------------------------------------------------------------

type sessionReadyMsg struct {
	session Session
	info    *relay.Info
}

type sessionFailedMsg struct{ err error }

type relayEventMsg struct{ event relay.Event }

type eventsClosedMsg struct{}

type sentMsg struct{ err error }

type whoMsg struct {
	participants []relay.Participant
	err          error
}

// --------------------------------------------------------------------------
// Update
// --------------------------------------------------------------------------

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)

	case sessionReadyMsg:
		m.session = msg.session
		m.info = msg.info
		m.events = msg.session.Events()
		m.roomID = msg.info.RoomID
		m.username = msg.info.Username
		m.senderID = msg.info.SenderID
		m.online = len(msg.info.Participants)
		m.phase = phaseChat
		m.unmaskInput()

		m.note(fmt.Sprintf("Joined as %s", m.username))
		if n := len(msg.info.History); n > 0 {
			m.note(fmt.Sprintf("Loaded %d retained messages.", n))
			for _, message := range msg.info.History {
				m.appendMessage(message)
			}
		} else {
			m.note("Loaded 0 retained messages.")
		}
		m.note("Type /help for commands.")
		return m, waitForEvent(m.events)

	case sessionFailedMsg:
		m.err = msg.err.Error()
		m.outcome = outcomeFor(msg.err)
		m.phase = phaseDone
		return m, tea.Quit

	case relayEventMsg:
		return m.handleEvent(msg.event)

	case eventsClosedMsg:
		m.note("Disconnected from the relay.")
		if m.outcome == OutcomeOK {
			m.outcome = OutcomeTransport
		}
		m.phase = phaseDone
		return m, tea.Quit

	case sentMsg:
		if msg.err != nil {
			m.note(fmt.Sprintf("Could not send: %v", msg.err))
		}
		return m, nil

	case whoMsg:
		if msg.err != nil {
			m.note(fmt.Sprintf("Could not list participants: %v", msg.err))
			return m, nil
		}
		names := make([]string, 0, len(msg.participants))
		for _, p := range msg.participants {
			names = append(names, p.Username)
		}
		m.online = len(names)
		m.note(fmt.Sprintf("%d online: %s", len(names), strings.Join(names, ", ")))
		return m, nil
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyCtrlC:
		// Spec §6.3: the first Ctrl+C is /quit; a second terminates immediately.
		if m.quitting {
			m.phase = phaseDone
			return m, tea.Quit
		}
		m.quitting = true
		m.note("Leaving… (press Ctrl+C again to force)")
		return m, m.quit()

	case tea.KeyEnter:
		return m.handleEnter()
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m Model) handleEnter() (tea.Model, tea.Cmd) {
	value := m.input.Value()

	switch m.phase {
	case phaseCreatePassword:
		m.err = ""
		if value == "" {
			// A5: Enter on an empty prompt accepts the suggestion.
			m.password = m.suggested
			m.phase = phaseConfirmCopied
			m.input.SetValue("")
			return m, nil
		}
		if err := validatePassword(value); err != nil {
			m.err = err.Error()
			m.input.SetValue("")
			return m, nil
		}
		// §6.1 step 5: a user-entered password is confirmed by retyping it.
		m.firstTyped = value
		m.phase = phaseRetype
		m.input.SetValue("")
		return m, nil

	case phaseRetype:
		if value != m.firstTyped {
			// AC: a mismatched retype re-prompts rather than failing out.
			m.err = "Passwords did not match. Try again."
			m.firstTyped = ""
			m.phase = phaseCreatePassword
			m.input.SetValue("")
			return m, nil
		}
		m.password = value
		m.input.SetValue("")
		return m.connect()

	case phaseConfirmCopied:
		// §9.2: a generated password is displayed once and the user confirms they
		// copied it. Headless skips this — a process has nothing to confirm (A15).
		m.input.SetValue("")
		return m.connect()

	case phaseJoinPassword:
		if err := validatePassword(value); err != nil {
			m.err = err.Error()
			m.input.SetValue("")
			return m, nil
		}
		m.password = value
		m.input.SetValue("")
		return m.connect()

	case phaseChat:
		if value == "" {
			return m, nil
		}
		m.input.SetValue("")
		return m.submit(value)
	}
	return m, nil
}

func (m Model) submit(value string) (tea.Model, tea.Cmd) {
	if !strings.HasPrefix(value, "/") {
		session := m.session
		return m, func() tea.Msg {
			_, err := session.Send(context.Background(), value)
			return sentMsg{err: err}
		}
	}

	command, _, _ := strings.Cut(value, " ")

	switch command {
	case "/help":
		m.note("/help — this message")
		m.note("/who — who is in the room")
		m.note("/quit — leave and exit")
		m.note("The relay can read every message. skulk is not end-to-end encrypted yet.")
		return m, nil

	case "/who":
		session := m.session
		return m, func() tea.Msg {
			participants, err := session.Who(context.Background())
			return whoMsg{participants: participants, err: err}
		}

	case "/quit":
		m.phase = phaseDone
		return m, m.quit()

	default:
		// Spec §6.3: an unknown command is a LOCAL error and is never sent. A typo
		// must not become a public message.
		m.note(fmt.Sprintf("Unknown command %s. Type /help.", command))
		return m, nil
	}
}

func (m Model) handleEvent(event relay.Event) (tea.Model, tea.Cmd) {
	switch event.Kind {
	case relay.EventMessage:
		m.appendMessage(event.Message)

	case relay.EventPresence:
		if event.Presence.Action == "joined" {
			m.note(fmt.Sprintf("%s joined.", event.Presence.Username))
		} else {
			m.note(fmt.Sprintf("%s left.", event.Presence.Username))
		}
		m.online = event.Presence.ParticipantCount

	case relay.EventRoomExpired:
		m.note("This room expired. Disconnecting.")
		m.outcome = OutcomeNoRoom
		m.phase = phaseDone
		return m, tea.Quit

	case relay.EventDisconnect:
		m.note(fmt.Sprintf("Disconnected: %s", event.Reason))
		m.outcome = OutcomeTransport
		m.phase = phaseDone
		return m, tea.Quit
	}
	return m, waitForEvent(m.events)
}

func (m Model) connect() (tea.Model, tea.Cmd) {
	m.phase = phaseConnecting
	m.status = "Connecting…"

	cfg := m.cfg
	roomID := m.roomID
	password := m.password

	return m, func() tea.Msg {
		ctx := context.Background()

		if !cfg.Joining && roomID == "" {
			generated, err := cfg.NewRoomID()
			if err != nil {
				return sessionFailedMsg{err: err}
			}
			roomID = generated
		}

		session, err := cfg.Dial(ctx, cfg.Server)
		if err != nil {
			return sessionFailedMsg{err: err}
		}

		var info *relay.Info
		if cfg.Joining {
			info, err = session.Join(ctx, roomID, password)
		} else {
			info, err = session.Create(ctx, roomID, password)
		}
		if err != nil {
			_ = session.Close()
			return sessionFailedMsg{err: err}
		}
		return sessionReadyMsg{session: session, info: info}
	}
}

func (m Model) quit() tea.Cmd {
	session := m.session
	return func() tea.Msg {
		if session != nil {
			_ = session.Close()
		}
		return tea.Quit()
	}
}

// waitForEvent is the standard bubbletea pump: receive one event, hand it to the
// model as a message, and re-arm. Kept as a Cmd over a plain channel rather than a
// goroutine calling Program.Send, so tests can drive the model without a Program.
func waitForEvent(events <-chan relay.Event) tea.Cmd {
	if events == nil {
		return nil
	}
	return func() tea.Msg {
		event, ok := <-events
		if !ok {
			return eventsClosedMsg{}
		}
		return relayEventMsg{event: event}
	}
}

// --------------------------------------------------------------------------
// View
// --------------------------------------------------------------------------

var (
	statusStyle = lipgloss.NewStyle().Bold(true)
	noticeStyle = lipgloss.NewStyle().Faint(true)
)

func (m Model) View() string {
	switch m.phase {
	case phaseCreatePassword:
		return m.createPasswordView()
	case phaseRetype:
		return m.section("Confirm password:", "Type it again.")
	case phaseConfirmCopied:
		return m.section(
			fmt.Sprintf("Your room password is:\n\n    %s\n", m.password),
			"Copy it somewhere safe — it is shown once. Press Enter to continue.")
	case phaseJoinPassword:
		return m.section(fmt.Sprintf("Joining %s", m.roomID), "Password:")
	case phaseConnecting:
		return "Connecting…\n"
	case phaseDone:
		if m.err != "" {
			return fmt.Sprintf("%s\n", m.err)
		}
		return strings.Join(m.lines, "\n") + "\n"
	default:
		return m.chatView()
	}
}

func (m Model) createPasswordView() string {
	var b strings.Builder
	b.WriteString("Creating a room.\n\n")
	b.WriteString(fmt.Sprintf("Suggested passphrase:\n\n    %s\n\n", m.suggested))
	b.WriteString("Press Enter to generate a strong passphrase, or type your own:\n")
	if m.err != "" {
		b.WriteString("\n" + m.err + "\n")
	}
	b.WriteString("\n" + m.input.View() + "\n")
	return b.String()
}

func (m Model) section(heading, prompt string) string {
	var b strings.Builder
	b.WriteString(heading + "\n\n")
	b.WriteString(prompt + "\n")
	if m.err != "" {
		b.WriteString("\n" + m.err + "\n")
	}
	b.WriteString("\n" + m.input.View() + "\n")
	return b.String()
}

// chatView is wireframe panel 1: a thin status bar, the transcript, one input
// line. The continuity segment the wireframe also shows is M4 and deliberately
// absent — a status bar cannot report a property nothing computes yet.
func (m Model) chatView() string {
	var b strings.Builder

	b.WriteString(statusStyle.Render(fmt.Sprintf("%s  ·  %d online", m.roomID, m.online)))
	b.WriteString("\n\n")

	lines := m.lines
	if visible := m.transcriptHeight(); visible > 0 && len(lines) > visible {
		lines = lines[len(lines)-visible:]
	}
	b.WriteString(strings.Join(lines, "\n"))
	b.WriteString("\n\n")
	b.WriteString(m.input.View())
	b.WriteString("\n")
	return b.String()
}

func (m Model) transcriptHeight() int {
	// status bar + blank + blank + input + newline
	const chrome = 5
	if m.height <= chrome {
		return 0
	}
	return m.height - chrome
}

func (m *Model) note(text string) {
	m.lines = append(m.lines, noticeStyle.Render("— "+text+" —"))
}

func (m *Model) appendMessage(message relay.Message) {
	m.lines = append(m.lines, fmt.Sprintf("%s  %-16s %s",
		clockOf(message.ReceivedAt), message.SenderUsername, message.Text))
}

// clockOf renders HH:MM from protocol v0's canonical timestamp. It is display
// only — nothing downstream parses it back.
func clockOf(timestamp string) string {
	if len(timestamp) >= 16 {
		return timestamp[11:16]
	}
	return "--:--"
}

func validatePassword(password string) error {
	switch n := len(password); {
	case n < protocol.MinPasswordBytes:
		return fmt.Errorf("Password must be at least %d bytes.", protocol.MinPasswordBytes)
	case n > protocol.MaxPasswordBytes:
		return fmt.Errorf("Password must be at most %d bytes.", protocol.MaxPasswordBytes)
	default:
		return nil
	}
}

func outcomeFor(err error) Outcome {
	switch relay.Code(err) {
	case protocol.CodeAuthenticationFailed:
		return OutcomeAuthFailed
	case protocol.CodeRoomNotFound, protocol.CodeRoomExpired:
		return OutcomeNoRoom
	case protocol.CodeRoomFull:
		return OutcomeCapacity
	case protocol.CodeUnsupportedProtocolVersion:
		return OutcomeProtocol
	case "":
		return OutcomeTransport
	default:
		return OutcomeFailure
	}
}
