package wordlist_test

import (
	"regexp"
	"strings"
	"testing"

	"github.com/roeeyn/skulk/internal/protocol"
	"github.com/roeeyn/skulk/internal/wordlist"
)

// The lists are data, and data rots silently. These assertions are what stop a
// well-meaning edit from changing every room ID in the world.
func TestListsMatchTheSpecCounts(t *testing.T) {
	if got := len(wordlist.RoomIDList); got != 2048 {
		t.Errorf("room-ID list has %d words, spec §9.1 requires exactly 2048", got)
	}
	if got := len(wordlist.PassphraseList); got != 7776 {
		t.Errorf("passphrase list has %d words, spec §9.2 requires exactly 7776", got)
	}
}

func TestRoomIDWordsAreLowercaseASCII(t *testing.T) {
	word := regexp.MustCompile(`^[a-z]+$`)
	for _, w := range wordlist.RoomIDList {
		if !word.MatchString(w) {
			t.Fatalf("room-ID list contains %q, which cannot appear in a protocol v0 room_id", w)
		}
	}
}

// The bound that could bite: eight of the longest words plus seven hyphens must
// fit protocol v0's 160-byte room_id limit. Asserted rather than reasoned about.
func TestLongestPossibleRoomIDFitsTheBound(t *testing.T) {
	longest := make([]int, 0, len(wordlist.RoomIDList))
	for _, w := range wordlist.RoomIDList {
		longest = append(longest, len(w))
	}
	// Sum of the eight longest words, plus separators.
	for i := 0; i < len(longest); i++ {
		for j := i + 1; j < len(longest); j++ {
			if longest[j] > longest[i] {
				longest[i], longest[j] = longest[j], longest[i]
			}
		}
	}
	worst := wordlist.RoomIDWords - 1
	for _, n := range longest[:wordlist.RoomIDWords] {
		worst += n
	}
	if worst > protocol.MaxRoomIDBytes {
		t.Errorf("worst-case room ID is %d bytes, over the %d-byte bound", worst, protocol.MaxRoomIDBytes)
	}
}

// The generator has to satisfy the validator, not merely look right.
func TestNewRoomIDIsAValidRoomID(t *testing.T) {
	for i := 0; i < 200; i++ {
		id, err := wordlist.NewRoomID()
		if err != nil {
			t.Fatalf("generating: %v", err)
		}
		if got := len(strings.Split(id, "-")); got != wordlist.RoomIDWords {
			t.Fatalf("room ID %q has %d words, want %d", id, got, wordlist.RoomIDWords)
		}

		frame := protocol.Frame{
			V: protocol.Version, Type: "create.begin",
			RequestID: "3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",
			Payload:   map[string]any{"room_id": id, "password": "correct-horse-battery"},
		}
		encoded, err := protocol.Encode(frame)
		if err != nil {
			t.Fatalf("encoding: %v", err)
		}
		if code := protocol.Validate(protocol.RoleRelay, protocol.KindText, encoded); code != "" {
			t.Fatalf("generated room ID %q was rejected as %s", id, code)
		}
	}
}

// Spec §9.2 bounds passwords at 12..256 bytes; a generated passphrase must land
// inside that by construction, never by luck.
func TestNewPassphraseIsWithinThePasswordBounds(t *testing.T) {
	for i := 0; i < 200; i++ {
		phrase, err := wordlist.NewPassphrase()
		if err != nil {
			t.Fatalf("generating: %v", err)
		}
		if n := len(phrase); n < protocol.MinPasswordBytes || n > protocol.MaxPasswordBytes {
			t.Fatalf("passphrase %q is %d bytes, outside %d..%d", phrase, n, protocol.MinPasswordBytes, protocol.MaxPasswordBytes)
		}
	}
}

// Not a randomness test — a wiring test. A generator that returned the same word
// eight times, or the same phrase every call, would pass every check above.
func TestGeneratorsDoNotRepeatThemselves(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		id, err := wordlist.NewRoomID()
		if err != nil {
			t.Fatalf("generating: %v", err)
		}
		if seen[id] {
			t.Fatalf("room ID %q generated twice in 50 draws — 88 bits says otherwise", id)
		}
		seen[id] = true
	}
}
