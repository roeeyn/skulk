# Word lists

Committed, not generated. Spec §9.1 requires the room-ID list to be "versioned and
shared by all clients" — a list derived from whatever dictionary happens to sit on a
build machine is exactly what that is not, and regenerating it would silently change
every room ID in the world.

| File | Words | Source | SHA-256 (of the source download) |
| --- | ---: | --- | --- |
| `roomid-2048.txt` | 2,048 | [BIP-39 English](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt) | `2f5eed53a4727b4b…` |
| `passphrase-7776.txt` | 7,776 | [EFF long wordlist](https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt) | `addd35536511597a…` |

Both files hold one word per line, in their source order. The EFF file's leading
dice-roll column was stripped; nothing else was changed, filtered, or reordered.

## Why these two

**BIP-39 English** for room IDs: it is exactly 2,048 words as spec §9.1 requires, frozen
by a specification that will not move, and every word is lowercase ASCII `[a-z]{3,8}` —
so eight of them joined by `-` always satisfy protocol v0's `room_id` pattern, and the
worst case is 71 bytes against a 160-byte bound.

**EFF long wordlist** for passphrases: 7,776 words as spec §9.2 requires, chosen by the
EFF for being easy to type, hard to mishear, and free of near-duplicates.

## One wrinkle

Four EFF entries contain a hyphen: `drop-down`, `felt-tip`, `t-shirt`, `yo-yo`. Since
passphrases are joined with `-`, a generated passphrase can render with more than five
hyphens while still being six words.

This is cosmetic. The password is an opaque byte string — nothing in skulk ever splits
it back into words — so the ambiguity has no functional consequence. The alternative,
filtering those four out, would mean shipping a *derived* list that is no longer "the EFF
list", which is a worse trade for a rendering quirk.
