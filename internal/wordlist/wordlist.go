// Package wordlist generates room identifiers and passphrases from fixed,
// published word lists.
//
// Both lists are committed rather than generated at build time. Spec §9.1 requires
// the room-ID list to be "versioned and shared by all clients", and a list derived
// from whatever dictionary happens to be on the build machine is precisely what
// that is not — a regenerated list would silently change every room ID in the
// world. See data/README.md for sources and checksums.
package wordlist

import (
	"crypto/rand"
	_ "embed"
	"math/big"
	"strings"
)

//go:embed data/roomid-2048.txt
var roomIDWords string

//go:embed data/passphrase-7776.txt
var passphraseWords string

var (
	// RoomIDList is the 2,048-word list room identifiers are drawn from (spec §9.1).
	RoomIDList = strings.Fields(roomIDWords)
	// PassphraseList is the 7,776-word list generated passphrases are drawn from
	// (spec §9.2).
	PassphraseList = strings.Fields(passphraseWords)
)

const (
	// RoomIDWords is spec §9.1's count: 8 words from 2,048 is 88 bits.
	RoomIDWords = 8
	// PassphraseWords is spec §9.2's count: 6 words from 7,776 is ~77 bits, which
	// amendment A4 identifies as the difference between "infeasible" and "maybe"
	// for the offline dictionary attack a relay operator can mount.
	PassphraseWords = 6
)

// NewRoomID returns a fresh room identifier: eight words joined by "-", matching
// protocol v0's room_id pattern exactly.
//
// The room ID is a locator, not a credential (spec §9.1). Its entropy keeps rooms
// unlisted; it never substitutes for the password.
func NewRoomID() (string, error) {
	return pick(RoomIDList, RoomIDWords, "-")
}

// NewPassphrase returns a fresh six-word passphrase for a room password.
//
// Joined by "-" for the same reason room IDs are: it survives copy-paste and
// double-click selection better than spaces do. Four entries in the EFF list are
// themselves hyphenated ("drop-down", "t-shirt", "yo-yo", "felt-tip"), so a
// rendered passphrase may show more than five hyphens and still be six words —
// harmless, because the password is an opaque byte string that is never split
// back into words by anything.
func NewPassphrase() (string, error) {
	return pick(PassphraseList, PassphraseWords, "-")
}

func pick(list []string, count int, separator string) (string, error) {
	words := make([]string, count)
	max := big.NewInt(int64(len(list)))

	for i := range words {
		// crypto/rand, and Int rather than modulo: a modulo reduction over a list
		// size that does not divide the range biases the low words, and this is
		// the entropy the whole unlisted-rooms property rests on.
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		words[i] = list[n.Int64()]
	}
	return strings.Join(words, separator), nil
}
