# Security

> ## skulk is experimental and not production-ready.
>
> Messages are **not end-to-end encrypted**. The relay receives your message text and can
> read every word of it. There is **no rate limiting**, by design, so an internet-facing
> relay is vulnerable to password guessing, room floods, connection floods, and denial of
> service. It has never been audited.
>
> Do not use skulk for anything you would mind a stranger reading, and do not put one on
> the public internet expecting it to defend itself.

That is the whole thesis. The rest of this document is the detail behind it.

It is written in three parts, and the boundary between them matters more than anything
inside them:

1. **[What is true today](#1-what-is-true-today)** — claims about code that exists, each
   one pointing at the test that holds it up.
2. **[What the relay is trusted for](#2-what-the-relay-is-trusted-for)** — the parts of
   the system that are somebody's word rather than a guarantee.
3. **[What changes at M2 and M3](#3-what-changes-at-m2-and-m3)** — properties skulk does
   **not** have yet. Nothing in this section describes the software you can run today.

---

## 1. What is true today

skulk is at milestone **M1**. The wire protocol is `v0`.

### The relay reads everything

Not "may be able to" — it receives plaintext and stores it.

- **Message text arrives as plaintext** in the `chat.send` frame's `text` field, is stored
  in the room's history in that form, and is replayed in that form to anyone who joins
  later with the password.
- **The room password reaches the relay**, which hashes it with argon2id. A hostile or
  compromised relay sees the password itself, inside the TLS session, before it is hashed.
- **A memory dump of the relay host exposes every live room**: its password hash, its
  retained messages, and the identities of everyone connected.

### Transport is the only protection, and only if the operator arranged it

The relay speaks WebSocket. Whether that is `wss://` is a deployment decision that this
project cannot make for you.

The client does enforce one guard: it refuses to send a password over `ws://` to anything
but a loopback address (spec §7.2). That is a guard against your own mistake, not a promise
about the operator's configuration — a relay reachable at `wss://` may still be terminating
TLS at a proxy that logs everything behind it.

<sub>Enforced by `internal/relay/url_test.go` (`TestInsecureRefusalExplainsItself`).</sub>

### There is no rate limiting, deliberately

Spec §19 omits application-level rate limiting from this version: no token buckets, no
per-IP attempt counters, no cooldowns, no quotas. The consequence is stated there and worth
repeating: **an internet-facing relay without rate limiting is vulnerable to password
guessing, room floods, connection floods, and denial of service.**

What stands in its place is a set of **capacity bounds** — hard ceilings that stop the relay
consuming unbounded resources, which is a different thing from stopping an attacker trying.
The bounds and their defaults live in [`Skulkd.Limits`](skulkd/lib/skulkd/limits.ex) and are
summarised in the README's *Relay limits* section; they are not repeated here, so that there
is one place to change them.

They cover the number of active rooms, participants per room, retained history per room and
across all rooms, and how far behind a single client may fall.

**One of those bounds is best-effort, and saying so is part of the design.** The
mailbox-threshold backpressure that disconnects a client which has stopped reading uses
`Process.info(pid, :message_queue_len)`, which is a snapshot. Frames beyond it sit in the
web server's socket write buffer and in the kernel's send buffer, neither of which the relay
can see. The guarantee is that runaway growth is cut off, **not** an exact byte ceiling. A
bound described as exact when it is approximate is worse than no bound, because someone will
reason about it.

### Rooms are ephemeral, which is a privacy property and an availability caveat at once

A room is a process holding its own state. It is deleted when its inactivity TTL expires,
and **every room is destroyed when the relay restarts** — there is no database, no disk, no
backup. Nothing to seize after the fact, and nothing to recover after a crash.

The client keeps no history on disk either; leaving clears its in-memory transcript.

### The room ID is a locator, not a credential

Eight words, ~88 bits, generated client-side. It says where a room is, not that you may
enter it — the password does that. Rooms never appear in any listing or discovery endpoint,
and the relay logs a truncated digest of a room ID rather than the ID itself (spec §18.1).

<sub>Digest-only logging is asserted in `skulkd/test/skulkd/room_test.exs`.</sub>

### What the relay can see even when M3's encryption lands

Encryption will protect message contents. It will not hide **who connects, from where, when,
how often, how much they say, or which room they are in.** A relay operator, or anyone with
the operator's logs or network position, sees all of that today and will see all of it after
M3.

### Where secrets are and are not allowed to appear

Three rules with negative tests behind them, because "we are careful" is not a security
property:

| Rule | Held up by |
| --- | --- |
| A password is **never** accepted on the command line. `--password` and friends are refused before flag parsing, since process listings and shell history are not places for secrets. | `cmd/skulk/main_test.go` (`TestSecretFlagsAreRejectedBeforeAnythingElse`) |
| Password prompts **never echo**, and a generated password is displayed exactly once — `/room` shows the room ID again and deliberately will not repeat the password. | `internal/tui/model_test.go` (`TestPasswordPromptsNeverEcho`) |
| `--debug` output carries frame types, sizes, and connection states — **never** message text or secret material. | `internal/relay/debug_test.go` (`TestDebugLogsProtocolShapeAndNeverContent`), which pushes a known password, message, and room ID through a live session and fails if any appears |

### Two independent parsers, checked against each other

The relay (Elixir) and the client (Go) implement the wire protocol **separately** — there is
no shared parsing library. That is a deliberate design choice, and it cuts both ways: it
removes a single point of failure, and it creates the risk that the two disagree about what
a frame means.

So they are checked against each other. A golden corpus of frame vectors must be accepted or
rejected identically by both, and a differential fuzzing harness generates frames neither
author thought of and compares verdicts. That harness found four real divergences, all now
fixed and frozen as corpus vectors:

- **Duplicate JSON keys.** One parser kept the first occurrence and the other the last, so
  `{"text":"harmless","text":"actual"}` was a message the relay validated as one thing and
  every client displayed as another. Both now reject duplicates outright.
- **Unpaired surrogate escapes**, accepted by one parser and rejected by the other.
- **Trailing bytes after the frame**, accepted by one parser.
- **A denial of service in the relay's own validator**: three bytes, `[,]`, from an
  unauthenticated caller pinned a CPU indefinitely. Caught before it shipped.

The decision recording all of this is **D13** in
[`docs/protocol-v0.md`](docs/protocol-v0.md).

### Known gaps

Stated rather than left for you to discover:

- **skulk has never been audited**, by anyone.
- **Dependency vulnerability and license scanning is not wired into CI.** Spec §22.3
  requires it and it does not exist yet. Tracked as ROJ-50.
- **There is no `docs/self-hosting.md`, no `Dockerfile`, and no example configuration.**
  Deploying a relay today means reading the README and knowing what you are doing. Also
  ROJ-50.
- Message ordering, delivery, and presence are the relay's word — see the next section.

### Cryptographic dependencies

Everything skulk uses for cryptography today, pinned:

| Dependency | Version | Used for |
| --- | --- | --- |
| [`argon2_elixir`](https://hex.pm/packages/argon2_elixir) | `4.1.3` | argon2id hashing of the room password, relay-side |
| `comeonin` | `5.5.1` | the hashing behaviour interface `argon2_elixir` implements |

The Go client has **no cryptographic dependencies today** — it holds no keys, derives
nothing, and encrypts nothing. Transport security is whatever TLS the operator deployed.

Exact hashes are in [`skulkd/mix.lock`](skulkd/mix.lock). The version stated in this table is
checked against that lockfile by a test, because a pinned-version claim that has quietly gone
stale is precisely the kind of lie this document exists to prevent.

---

## 2. What the relay is trusted for

Distinct from what it is trusted *with*. Spec §10.2: even after end-to-end encryption
lands, the relay is trusted for

- **availability** — it can simply stop;
- **room existence reporting** — it can claim a room does not exist, or that one does;
- **presence and username assignment** — it chooses who appears to be in the room, and what
  they are called;
- **enforcing connection-scoped sender IDs**;
- **message ordering and delivery**.

**The relay can omit, delay, duplicate, reorder, or delete messages, and can lie about who
is present.** None of that is covered by any cryptographic guarantee in this project, now or
after M3. Milestone M4 adds a continuity mechanism that lets clients *detect* some of it
after the fact; it does not prevent it.

Usernames are relay-assigned metadata, not identity. They are unique among the currently
connected, they change every time you reconnect, and — since amendment A12 — the relay will
not hand out a name that still appears in a room's retained history, so a departed person's
messages cannot come to look as though a present person wrote them.

---

## 3. What changes at M2 and M3

**Nothing in this section is true of the software you can run today.** It is here so the
document has an obvious growth path and so the shape of the eventual design is not a
surprise.

- **M2 — OPAQUE authentication.** The password stops reaching the relay at all. The relay
  stores an OPAQUE registration record instead of a password hash, and a successful login
  yields an `export_key` the relay never sees.
- **M3 — end-to-end encryption.** Message text is replaced on the wire by a nonce and a
  ciphertext (XChaCha20-Poly1305). The relay stores ciphertext it cannot read, and the
  honesty notice at the top of the README is deleted — not one milestone sooner.
- **M4 — integrity.** A continuity fold lets clients detect a relay that has dropped,
  reordered, or forked the message stream.

Three things that will need saying plainly **once that code exists**, recorded now so they
are not quietly forgotten:

**The offline-recovery path (amendment A4), with all three inputs named.** Anyone holding
*all three* of a room's **OPAQUE registration record**, its **key envelope**, and the
**relay's OPAQUE server setup material** can mount an offline dictionary attack on the room
password, recover the `export_key`, unwrap the room key, and decrypt every retained message.

The relay operator qualifies. So does a memory dump, a compromised host, or a seized
snapshot. **Against that party, confidentiality is exactly password strength** — which is
why skulk offers a generated passphrase and makes accepting it the path of least resistance.
A generated six-word passphrase (~77 bits) puts the attack out of reach; a minimum-length
password you chose yourself may not.

**The BEAM cannot zeroize memory.** The relay runs on a garbage-collected runtime with no
way to reliably scrub a secret from memory after use. Combined with A4 above, that means a
memory capture of a relay host is a serious event and will remain one.

**Audit status of the OPAQUE implementation, stated carefully.** The Rust `opaque-ke` crate
that M2 will wrap received an independent review in 2021 sponsored by WhatsApp. That review
covered a 2021-era version, **not** the version this project would pin, and this project has
not been audited at all.

---

## Reporting a vulnerability

Report privately through **GitHub's security advisory form** on this repository
(*Security* → *Report a vulnerability*). That keeps the report between you and the
maintainer until there is something to say publicly.

Please include what you did, what happened, and what you expected. A frame that reproduces
it is worth more than a description of it — the corpus in
[`docs/protocol/corpus/`](docs/protocol/corpus/) is where such a frame would end up, with
attribution if you would like it.

**What you can expect:** an acknowledgement that a human has read it. skulk is maintained by
one person on an experimental project, so there is no response-time commitment beyond that,
and promising one would be a fiction.

**Please do not** test against a relay you do not operate. Running your own takes about a
minute — the README's quick start covers it.
