package tui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/roeeyn/skulk/internal/relay"
)

// An internal test, unlike the rest of the suite, because the palette is a
// rendering decision rather than a user-visible surface — and because the width
// assertion below has to change the global colour profile, which the external
// suite deliberately pins.

func TestSenderColoursAreStableAndSpreadOverThePalette(t *testing.T) {
	// Stable across calls, which is what "stable across sessions" reduces to: the
	// mapping is a pure function of the name, with no state to lose.
	for _, name := range []string{"bright-fox-17", "quiet-otter-42", "noble-kestrel-08"} {
		if colourOf(name) != colourOf(name) {
			t.Errorf("%s got two different colours", name)
		}
	}

	// Spread: a hash that piles every name onto one colour is worse than none.
	seen := map[lipgloss.Color]int{}
	for i := range 60 {
		seen[colourOf(fmt.Sprintf("adjective-animal-%02d", i))]++
	}
	if len(seen) < len(senderPalette)*2/3 {
		t.Errorf("60 usernames used only %d of %d colours", len(seen), len(senderPalette))
	}

	// The four that are the default foreground or background at one end or the
	// other; a name in one of them disappears on somebody's terminal.
	for _, colour := range senderPalette {
		switch colour {
		case "0", "7", "8", "15":
			t.Errorf("palette contains %q, which collides with a default", colour)
		}
	}
}

func TestYourOwnNameIsNotOneOfThePaletteColours(t *testing.T) {
	mine := senderStyle("quiet-otter-42", true)
	theirs := senderStyle("quiet-otter-42", false)

	if !mine.GetBold() {
		t.Error("your own name should be bold")
	}
	if mine.GetForeground() == theirs.GetForeground() {
		t.Error("your own name must not share a colour with the palette — telling " +
			"yourself apart is a different question from telling two others apart")
	}
}

// The ROJ-47 acceptance criterion, asserted rather than assumed.
//
// lipgloss measures printable cells, so colour SHOULD be free — but the rest of
// this package's tests run on the ASCII profile, which strips every style and
// would let this pass while proving nothing. So it switches to a real profile,
// and then checks that it actually did.
func TestColourNeverChangesTheMeasuredWidth(t *testing.T) {
	saved := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() { lipgloss.SetColorProfile(saved) })

	for _, width := range []int{120, 80, 60, 40, 30, 24} {
		m := New(Config{
			Server:    "ws://127.0.0.1:4000/v1/ws",
			Generate:  func() (string, error) { return "lentil-quartz-harbor-dusk", nil },
			NewRoomID: func() (string, error) { return "amber-river-copper-moon-forest-glass-harbor-star", nil },
		})
		m.phase = phaseChat
		m.width, m.height = width, 24
		m.online, m.senderID, m.username = 3, "u3Bk9QzR2mXvLp7TnAeYwQ", "quiet-otter-42"
		m.input.Prompt = m.username + " > "

		m.note("a system notice long enough that it has to wrap somewhere")
		for _, message := range []relay.Message{
			{SenderID: "u3Bk9QzR2mXvLp7TnAeYwQ", SenderUsername: "quiet-otter-42", ReceivedAt: "2026-08-20T14:07:52.418Z", Text: "one of mine"},
			{SenderID: "Kd8vN2pQ7rT4xW9yZa3bLc", SenderUsername: "bright-fox-17", ReceivedAt: "2026-08-20T14:08:02.000Z", Text: "and one of theirs, long enough to wrap on a narrow terminal"},
			{SenderID: "Zz1yX2wV3uT4sR5qP6oN7m", SenderUsername: "a-username-far-longer-than-the-column", ReceivedAt: "2026-08-20T14:08:30.000Z", Text: "clipped name"},
		} {
			m.appendMessage(message)
		}
		m.syncViewport()

		view := m.View()

		// Without this the whole test is vacuous: a stripped profile renders no
		// escapes at all and every width assertion below passes for free.
		if !strings.Contains(view, "\x1b[") {
			t.Fatalf("width %d: no escape sequences — the colour profile did not apply", width)
		}

		for _, row := range strings.Split(strings.TrimRight(view, "\n"), "\n") {
			if w := lipgloss.Width(row); w > width {
				t.Errorf("width %d: a styled row measures %d columns: %q", width, w, row)
			}
		}
	}
}

// Message bodies must still line up once the names around them are coloured:
// escape codes are bytes, and the padding they replaced counted bytes.
func TestColouredNamesStillAlign(t *testing.T) {
	saved := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() { lipgloss.SetColorProfile(saved) })

	m := Model{width: 100, senderID: "mine"}
	for _, name := range []string{"a", "bright-fox-17", "quiet-otter-42", "a-username-far-longer-than-the-column"} {
		m.appendMessage(relay.Message{
			SenderUsername: name, ReceivedAt: "2026-08-20T14:07:52.418Z", Text: "body",
		})
	}

	column := -1
	for i, row := range m.rows() {
		// Date separators and other rules have no body to align; skip them rather
		// than letting the first one become the baseline.
		if !strings.Contains(row, "body") {
			continue
		}

		at := lipgloss.Width(ansiPrefixBefore(row, "body"))
		if column == -1 {
			column = at
		} else if at != column {
			t.Errorf("row %d starts its body at column %d, want %d: %q", i, at, column, row)
		}
	}
	if column == -1 {
		t.Fatal("no message rows found — the fixture is not testing anything")
	}
}

// ansiPrefixBefore returns everything ahead of the first occurrence of marker.
func ansiPrefixBefore(row, marker string) string {
	if i := strings.Index(row, marker); i >= 0 {
		return row[:i]
	}
	return row
}

// A12's boundary is derived from snapshot_sequence, not guessed from timestamps —
// so a frame delivered live that carries a sequence at or below the snapshot is
// still history, and must look like it.
//
// This lives here rather than in the external suite because the distinction is
// Faint, which the ASCII profile strips: asserted over there it would compare two
// identical strings and pass forever.
func TestTheReplayBoundaryComesFromSnapshotSequence(t *testing.T) {
	saved := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() { lipgloss.SetColorProfile(saved) })

	m := Model{width: 100, snapshotSequence: 5}
	m.appendMessage(relay.Message{SenderUsername: "bright-fox-17", Sequence: 4, ReceivedAt: "2026-08-20T14:09:00.000Z", Text: "below"})
	m.appendMessage(relay.Message{SenderUsername: "bright-fox-17", Sequence: 6, ReceivedAt: "2026-08-20T14:09:10.000Z", Text: "above"})

	rows := m.rows()
	var replayed, live string
	for _, row := range rows {
		switch {
		case strings.Contains(row, "below"):
			replayed = row
		case strings.Contains(row, "above"):
			live = row
		}
	}
	if replayed == "" || live == "" {
		t.Fatalf("fixture did not render both messages: %q", rows)
	}
	if strings.ReplaceAll(replayed, "below", "") == strings.ReplaceAll(live, "above", "") {
		t.Error("a message at or below the snapshot must not render like a live one")
	}

	// And with no snapshot at all, nothing is history.
	none := Model{width: 100}
	none.appendMessage(relay.Message{SenderUsername: "bright-fox-17", Sequence: 4, ReceivedAt: "2026-08-20T14:09:00.000Z", Text: "below"})
	if strings.Contains(none.rows()[len(none.rows())-1], "\x1b[2m\x1b[3") {
		t.Error("with no snapshot sequence, no message should be marked as replayed")
	}
}
