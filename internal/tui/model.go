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
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

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

// entry is one logical transcript line, stored UNWRAPPED.
//
// Wrapping happens at render time, not here, because the terminal can be resized
// after a message arrives — a line wrapped on arrival would stay wrapped to the old
// width forever. Keeping prefix and body apart is what lets continuation lines hang
// under the message instead of under the timestamp.
type entry struct {
	// A message carries these; a notice leaves them empty.
	clock  string
	sender string
	self   bool // this client sent it — derived from sender id, not username

	indent string // a notice's literal prefix, if any
	body   string
	notice bool
}

// senderColumn is the width the username is padded to, so message bodies line up.
const senderColumn = 16

// prefix is the UNSTYLED prefix, which is the one the width arithmetic needs.
//
// It cannot be a stored string any more: styling the username means the rendered
// prefix contains escape bytes, and fmt's %-16s pads by byte count. Alignment
// would shatter the moment colour landed. Storing the parts and composing here
// keeps one definition of how wide a prefix is, whether or not it is coloured.
func (e entry) prefix() string {
	if e.sender == "" {
		return e.indent
	}
	name, pad := fitSender(e.sender)
	return e.clock + "  " + name + strings.Repeat(" ", pad) + " "
}

// render is prefix() with styling, and must measure exactly the same.
func (e entry) render() string {
	if e.sender == "" {
		return e.indent
	}
	name, pad := fitSender(e.sender)
	return clockStyle.Render(e.clock) + "  " +
		senderStyle(e.sender, e.self).Render(name) + strings.Repeat(" ", pad) + " "
}

// fitSender returns the username clipped to the sender column and the padding it
// needs. Clipping happens before styling, so escape bytes can never be cut in half.
func fitSender(sender string) (string, int) {
	if w := lipgloss.Width(sender); w > senderColumn {
		return ansi.Truncate(sender, senderColumn, ""), 0
	} else {
		return sender, senderColumn - w
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

	phase    phase
	input    textinput.Model
	viewport viewport.Model
	width    int
	height   int
	status   string
	outcome  Outcome

	suggested  string
	password   string
	firstTyped string

	session  Session
	info     *relay.Info
	events   <-chan relay.Event
	entries  []entry
	online   int
	roomID   string
	username string
	senderID string

	quitting  bool // a first Ctrl+C has been seen
	following bool // the transcript is pinned to the live edge
	err       string
}

// The chat frame's fixed rows: a status bar, a blank line, the transcript, and a
// three-row input box sitting flush beneath it. Alt-screen means the app owns
// exactly the rows it was given, so the transcript takes whatever is left and
// never one row more.
const chatChrome = 5

// Fallback geometry for a model that has not been told the terminal size yet.
const (
	defaultWidth  = 80
	defaultHeight = 24
)

// New builds a model for either flow. Nothing connects until the password is in.
func New(cfg Config) Model {
	input := textinput.New()
	input.Prompt = "> "
	input.CharLimit = protocol.MaxTextBytes
	input.Focus()

	// A model that is never told the terminal size still has to render — most of
	// this package's tests drive Update directly and never send a WindowSizeMsg,
	// and a viewport of height zero shows nothing at all. Default here, and let the
	// resize that arrives on startup override it.
	m := Model{
		cfg:       cfg,
		input:     input,
		roomID:    cfg.RoomID,
		width:     defaultWidth,
		height:    defaultHeight,
		viewport:  viewport.New(defaultWidth, defaultHeight-chatChrome),
		following: true,
	}

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

		// The room id is generated HERE rather than in connect(), because §9.2
		// displays a generated password exactly once and an invite is both halves.
		// Born a screen later, the id arrived seconds too late to be copied with the
		// password — which is precisely how the first tester lost it. connect()'s
		// `roomID == ""` guard lets this value through untouched.
		if roomID, err := cfg.NewRoomID(); err == nil {
			m.roomID = roomID
		} else {
			m.err = fmt.Sprintf("could not generate a room id: %v", err)
		}
		m.maskInput()
	}
	m.syncViewport()
	return m
}

// NewProgram builds the bubbletea program skulk runs, full-screen.
//
// Alt-screen is a program option rather than a tea.EnterAltScreen command
// returned from Init, because bubbletea's own documentation warns that commands
// run asynchronously: one returned from Init races the first render and can leave
// a stray frame behind in the scrollback it was supposed to preserve. Keeping it
// here also leaves exactly one definition of what a skulk program is, which is
// what lets a test run the real thing.
func NewProgram(model Model, opts ...tea.ProgramOption) *tea.Program {
	return tea.NewProgram(model, append([]tea.ProgramOption{tea.WithAltScreen()}, opts...)...)
}

// Outcome reports how the session ended, for the caller's exit code.
func (m Model) Outcome() Outcome { return m.outcome }

// Reason reports why the session ended, empty on a clean exit.
//
// It exists because the program runs full-screen: leaving the alternate screen
// restores whatever was on the terminal before skulk started, which takes the
// final frame with it. An explanation that only ever lived on screen would be
// erased at exactly the moment the user needs to read it, so cmd/skulk prints
// this to stderr after the program returns.
//
// A successful exit has nothing to explain, and the check is against the outcome
// rather than the field because err also holds prompt errors: aborting at a
// password prompt that is showing one is the user reading it and choosing to
// leave, not a failure to report back at them.
func (m Model) Reason() string {
	if m.outcome == OutcomeOK {
		return ""
	}
	return m.err
}

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
	next, cmd := m.update(msg)

	// The one place where the viewport is made to agree with the entries and the
	// terminal size, run after every message. Syncing at each append instead would
	// mean every future caller of note() has to remember to.
	next.syncViewport()
	return next, cmd
}

func (m Model) update(msg tea.Msg) (Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// Clamped here so that nothing downstream has to ask whether it has a size.
		if msg.Width > 0 {
			m.width = msg.Width
		}
		if msg.Height > 0 {
			m.height = msg.Height
		}
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

		// The relay assigns the username, so this is the first moment there is one
		// to show. Password prompts keep the bare "> ".
		m.input.Prompt = m.username + " > "

		// The prompt and the session share one err field, and a rejected password is
		// stale the moment a connection succeeds. Leaving it set makes it the final
		// frame in place of the transcript, and Reason() prints it to stderr after a
		// clean exit. The real failure path overwrites this field anyway, so nothing
		// worth keeping is lost.
		m.err = ""

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

		// Only on create: someone who joined was already given these. Recall on
		// demand (/room) and show-at-the-right-moment are different failure modes,
		// and the tester hit the second one — they lost the id before learning a
		// command existed.
		if !m.cfg.Joining {
			m.invite()
		}
		return m, waitForEvent(m.events)

	case sessionFailedMsg:
		m.err = msg.err.Error()
		m.outcome = outcomeFor(msg.err)
		m.phase = phaseDone
		return m, tea.Quit

	case relayEventMsg:
		return m.handleEvent(msg.event)

	case eventsClosedMsg:
		if m.leaving() {
			return m, nil
		}
		m.note("Disconnected from the relay.")
		m.err = "disconnected from the relay"
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

func (m Model) handleKey(msg tea.KeyMsg) (Model, tea.Cmd) {
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

	// Scrolling is handled here and the key is never forwarded, in either
	// direction. bubbles' viewport binds f, b, u, d, j, k, h, l and space by
	// default, so handing it a KeyMsg would make typing those letters scroll the
	// transcript; and forwarding PgUp to the input types into the message box.
	case tea.KeyPgUp:
		m.viewport.PageUp()
		m.following = m.viewport.AtBottom()
		return m, nil

	case tea.KeyPgDown:
		m.viewport.PageDown()
		m.following = m.viewport.AtBottom()
		return m, nil
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m Model) handleEnter() (Model, tea.Cmd) {
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

func (m Model) submit(value string) (Model, tea.Cmd) {
	// Acting on the room is a decision to be at the live edge: whatever this does,
	// the user wants to see it happen rather than read about it later. It is also
	// the way back down without paging there.
	m.following = true

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
		m.note("/room — the room id and a join command to share")
		m.note("/quit — leave and exit")
		m.note("PgUp / PgDn — scroll back; sending a message returns you to the latest")
		m.note("The relay can read every message. skulk is not end-to-end encrypted yet.")
		return m, nil

	case "/room":
		m.invite()
		// §9.2 displays a generated password once. Saying so is the useful part:
		// otherwise the absence reads as an oversight rather than a rule.
		m.note("The password appeared once and is not shown again.")
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

func (m Model) handleEvent(event relay.Event) (Model, tea.Cmd) {
	// Closing the socket makes the relay's read loop fail, which emits a disconnect
	// and then closes the event channel. That is the shutdown completing, not the
	// relay dropping us: acting on it would race a clean exit code to 3 and — now
	// that the reason is printed to stderr — tell the user their own /quit was a
	// dropped connection.
	if m.leaving() {
		return m, nil
	}

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
		m.err = "this room expired"
		m.outcome = OutcomeNoRoom
		m.phase = phaseDone
		return m, tea.Quit

	case relay.EventDisconnect:
		m.note(fmt.Sprintf("Disconnected: %s", event.Reason))
		m.err = fmt.Sprintf("disconnected: %s", event.Reason)
		m.outcome = OutcomeTransport
		m.phase = phaseDone
		return m, tea.Quit
	}
	return m, waitForEvent(m.events)
}

func (m Model) connect() (Model, tea.Cmd) {
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

// leaving reports that the user has already asked to go, whether by /quit or by
// Ctrl+C. Everything the relay says after that point is teardown noise.
func (m Model) leaving() bool { return m.quitting || m.phase == phaseDone }

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

	// The composing area as a region rather than a stray line. Box-drawing
	// characters need no colour, so this renders the same on the ASCII profile.
	inputBoxStyle = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)

	clockStyle = lipgloss.NewStyle()
)

// senderStyle is how a username is drawn. Colour arrives in a later commit; this
// keeps the refactor a refactor.
func senderStyle(string, bool) lipgloss.Style { return lipgloss.NewStyle() }

func (m Model) View() string {
	switch m.phase {
	case phaseCreatePassword:
		return m.createPasswordView()
	case phaseRetype:
		return m.section("Confirm password:", "Type it again.")
	case phaseConfirmCopied:
		// Both halves, together. Either one alone is not an invite, and this is the
		// only screen the password ever appears on.
		return m.section(
			fmt.Sprintf("Your room is ready. Copy both — the password is shown once.\n\n"+
				"    Room ID     %s\n    Password    %s\n", m.roomID, m.password),
			"Anyone with both can join. Send the password through a channel you trust.\n"+
				"Press Enter to continue.")
	case phaseJoinPassword:
		return m.section(fmt.Sprintf("Joining %s", m.roomID), "Password:")
	case phaseConnecting:
		return "Connecting…\n"
	case phaseDone:
		if m.err != "" {
			return fmt.Sprintf("%s\n", m.err)
		}
		return strings.Join(m.rows(), "\n") + "\n"
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

	b.WriteString(statusStyle.Render(m.statusBar()))
	b.WriteString("\n\n")

	// The viewport always renders exactly its own height, so the frame is exactly
	// as tall as the terminal — one row more and a full-screen app scrolls its own
	// display, which looks like the program tearing itself in half.
	b.WriteString(m.viewport.View())
	b.WriteString("\n")
	b.WriteString(m.inputBox())
	return b.String()
}

// statusBar is wireframe panel 1's thin bar: room and participant count.
//
// The room id is eight words — 48 columns is typical — so on a narrow terminal the
// bar overflows the screen exactly the way long messages used to. The wireframe
// already shows the answer: elide the middle of the id and keep both ends, which is
// what a human needs to recognise which room they are in.
func (m Model) statusBar() string {
	return joinSegments(m.width,
		// Flex: the room id absorbs whatever the other segments leave, shortening
		// from the middle so both ends survive.
		segment{text: m.roomID, flex: true, shrink: elide},
		// On a very narrow terminal the word "online" is a luxury; the NUMBER is
		// not, because "am I alone in here?" is what the bar exists to answer.
		segment{text: fmt.Sprintf("%d online", m.online), shrink: dropTrailingWord},
	)
}

// segment is one piece of the status bar.
//
// A format string would have been shorter today and wrong at M4, which appends a
// continuity indicator to this bar (wireframe panel 1). A list absorbs a new
// piece; a Sprintf has to be rewritten, and so does every width rule around it.
type segment struct {
	text string
	flex bool // takes the width the others do not need; at most one
	// shrink makes the text fit a limit, or is nil to take it or leave it.
	shrink func(text string, limit int) string
}

const segmentSeparator = "  ·  "

func joinSegments(width int, segments ...segment) string {
	separator := lipgloss.Width(segmentSeparator)
	rendered := make([]string, len(segments))

	// Fixed segments first, each shrunk if it alone would eat half the bar.
	spoken := 0
	for i, s := range segments {
		if s.flex {
			continue
		}
		text := s.text
		if s.shrink != nil && lipgloss.Width(text)+separator > width/2 {
			text = s.shrink(text, width/2)
		}
		rendered[i] = text
		spoken += lipgloss.Width(text) + separator
	}

	// Then the flex segment, into what is left.
	for i, s := range segments {
		if !s.flex {
			continue
		}
		text := s.text
		if available := width - spoken; s.shrink != nil && lipgloss.Width(text) > available {
			text = s.shrink(text, available)
		}
		rendered[i] = text
	}

	// Final guard: at absurd widths nothing fits properly, and overflowing the
	// screen is worse than losing characters.
	return ansi.Truncate(strings.Join(rendered, segmentSeparator), width, "")
}

// dropTrailingWord shortens "3 online" to "3".
func dropTrailingWord(text string, _ int) string {
	if i := strings.IndexByte(text, ' '); i > 0 {
		return text[:i]
	}
	return text
}

// elide shortens a hyphenated room id from the middle, keeping the first words and
// the last one: amber-river-copper-…-star.
func elide(roomID string, limit int) string {
	if limit < 5 {
		return ansi.Truncate(roomID, max(limit, 1), "")
	}

	words := strings.Split(roomID, "-")
	if len(words) < 3 {
		return ansi.Truncate(roomID, limit, "…")
	}

	last := words[len(words)-1]
	tail := "…-" + last

	head := ""
	for _, word := range words[:len(words)-1] {
		candidate := head + word + "-"
		if lipgloss.Width(candidate+tail) > limit {
			break
		}
		head = candidate
	}
	if head == "" {
		return ansi.Truncate(roomID, limit, "…")
	}
	return head + tail
}

// transcriptHeight is every row the chrome does not claim.
//
// Below five rows there is nowhere to put a status bar, a transcript and an input
// line at once. The frame keeps its minimum rather than rendering nothing, and a
// terminal that small is on its own.
// inputBox draws the input inside a border exactly as wide as the terminal and
// exactly three rows tall.
//
// Both caps are load-bearing rather than defensive. lipgloss wraps content to fit
// a width, so without MaxHeight a prompt longer than a narrow box turns three rows
// into four and the frame stops matching the terminal; and MaxWidth covers the one
// frame after a resize where the input's scroll offset is still the old one.
func (m Model) inputBox() string {
	return inputBoxStyle.
		Width(m.width - inputBoxStyle.GetHorizontalBorderSize()).
		MaxHeight(3).
		MaxWidth(m.width).
		Render(m.input.View())
}

// fitInput sizes the text field to what is left inside the box, so a long message
// scrolls sideways instead of wrapping the box open.
func (m *Model) fitInput() {
	inner := m.width - inputBoxStyle.GetHorizontalBorderSize() - inputBoxStyle.GetHorizontalPadding()

	// bubbles counts the visible characters, so the prompt and the cursor's own
	// column come off the top.
	m.input.Width = max(1, inner-lipgloss.Width(m.input.Prompt)-1)

	// The scroll offset is recomputed in textinput's Update, not its View, so a
	// width set here would not take effect until the next keystroke. SetCursor
	// recomputes it now.
	m.input.SetCursor(m.input.Position())
}

func (m Model) transcriptHeight() int {
	return max(1, m.height-chatChrome)
}

// syncViewport re-renders the transcript into the viewport at the current size.
//
// Whether to follow is answered by a flag rather than by asking the viewport
// whether it is at the bottom, because by the time this runs the geometry may
// already have changed underneath the question. The flag is written where the
// user actually decides: scrolling away, or sending something.
func (m *Model) syncViewport() {
	m.fitInput()

	m.viewport.Width = m.width
	m.viewport.Height = m.transcriptHeight()
	m.viewport.SetContent(strings.Join(m.rows(), "\n"))

	if m.following {
		m.viewport.GotoBottom()
		return
	}

	// Someone is reading history. Re-clamp rather than move them: a resize can
	// shrink the transcript in rows under an offset that was valid a moment ago.
	m.viewport.SetYOffset(m.viewport.YOffset)
}

func (m *Model) note(text string) {
	m.entries = append(m.entries, entry{body: "— " + text + " —", notice: true})
}

// plain is an indented system line without note's dashes, for a value the user is
// meant to select and copy — dashes would come along with the selection. The
// indent lives in prefix so that a wrap hangs under it instead of resetting to
// column zero.
func (m *Model) plain(text string) {
	m.entries = append(m.entries, entry{indent: "    ", body: text, notice: true})
}

// invite writes what another person needs to get here. Never the password: it
// travels out of band, and §9.2 shows it once.
//
// The room id gets a line to itself rather than being embedded in a ready-made
// command. An eight-word id plus a relay URL is close to a hundred columns, so a
// one-line command wraps on any normal terminal — and a wrapped command is worse
// than no command, because selecting it drags in a newline that splits it in two
// when pasted. The id always fits, and the id is the part you actually send.
func (m *Model) invite() {
	m.note("Share this room id")
	m.plain(m.roomID)
	m.note(fmt.Sprintf("They run: skulk join <that id> --server %s", m.cfg.Server))
}

func (m *Model) appendMessage(message relay.Message) {
	m.entries = append(m.entries, entry{
		clock:  clockOf(message.ReceivedAt),
		sender: message.SenderUsername,
		// By sender id, not username: usernames are connection-scoped and A12 only
		// keeps retained history from reusing one. This is headless decision H6's
		// derivation, and sessionReadyMsg sets senderID before replaying history,
		// so a replayed message of your own is still yours.
		self: message.SenderID != "" && message.SenderID == m.senderID,
		body: message.Text,
	})
}

// rows renders the transcript to actual terminal rows, wrapped to width.
//
// A message is one entry but can be many rows, which is why the visible-height
// arithmetic counts rows rather than entries: counting entries would push the input
// line off the bottom of the screen as soon as anyone said something long.
func (m Model) rows() []string {
	width := m.width

	var out []string
	for _, e := range m.entries {
		prefix := e.prefix()
		indent := lipgloss.Width(prefix)

		// Too narrow to hang the body under the prefix: wrap the whole line flat
		// rather than producing a one-word-per-row column. The prefix is wrapped
		// along with the body here, so it goes out unstyled — at this width the
		// sender colour is the first thing worth losing.
		if width-indent < 24 {
			for _, line := range wrap(prefix+e.body, width) {
				out = append(out, style(line, e.notice))
			}
			continue
		}

		for i, line := range wrap(e.body, width-indent) {
			if i == 0 {
				out = append(out, e.render()+style(line, e.notice))
			} else {
				out = append(out, strings.Repeat(" ", indent)+style(line, e.notice))
			}
		}
	}
	return out
}

// wrap word-wraps to a column limit, breaking words only when they do not fit at
// all, and measuring wide characters correctly — a line of CJK is twice as wide as
// its rune count suggests.
func wrap(text string, limit int) []string {
	if limit < 1 {
		return []string{text}
	}
	return strings.Split(ansi.WrapWc(text, limit, " "), "\n")
}

func style(line string, notice bool) string {
	if notice {
		return noticeStyle.Render(line)
	}
	return line
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
