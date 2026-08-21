package tui

import (
	"hash/fnv"

	"github.com/charmbracelet/lipgloss"
)

// senderPalette is the twelve colours a username can be drawn in.
//
// Basic ANSI numbers rather than 256-colour values, deliberately: the terminal's
// own theme decides what "4" looks like, which is how one palette stays legible
// on a light background and a dark one without querying the terminal for its
// background colour — a query that needs a real TTY and guesses wrong in tests.
//
// 0, 7, 8 and 15 are missing because they are the default foreground and
// background at one end or the other, so a name in one of them would vanish on
// somebody's terminal.
var senderPalette = []lipgloss.Color{
	"1", "2", "3", "4", "5", "6",
	"9", "10", "11", "12", "13", "14",
}

// colourOf maps a username to a palette entry.
//
// Hashed rather than handed out in arrival order, so a name keeps its colour
// across restarts AND across participants: everyone in the room sees
// bright-fox-17 in the same colour. Arrival order would give each person a
// different mapping, which is colourful rather than scannable.
func colourOf(username string) lipgloss.Color {
	sum := fnv.New32a()
	_, _ = sum.Write([]byte(username))
	return senderPalette[sum.Sum32()%uint32(len(senderPalette))]
}

// senderStyle draws a username: palette colour for other people, bold and
// uncoloured for you.
//
// Your own name deliberately sits outside the palette. Finding yourself in a
// transcript is a different question from telling two other people apart, and a
// colour that is also somebody else's cannot answer it.
func senderStyle(sender string, self bool) lipgloss.Style {
	if self {
		return lipgloss.NewStyle().Bold(true)
	}
	return lipgloss.NewStyle().Foreground(colourOf(sender))
}
