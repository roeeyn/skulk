# skulk headless interface v1

**Status:** normative for `skulk --headless`, from milestone M0 onward.
**Version:** `headless_version: 1`, independent of the wire protocol version.
**Implemented by:** ROJ-33 (M0-5). **Compatibility suite:** the ExUnit integration
harness (ROJ-35), which consumes this document exactly as an agent does.
**Derived from:** design amendment **A15**, spec §6.3, §9.2, §17, §20.

> **⚠️ v0 IS NOT ENCRYPTED.** At M0 the relay reads every message (see
> [`docs/protocol-v0.md`](protocol-v0.md)). Nothing in this document should be read as a
> privacy promise. E2EE lands at M3 — and, as §2 explains, agents will not have to change
> a line when it does.

---

## 1. What this is

`skulk --headless` speaks newline-delimited JSON on stdin and stdout instead of drawing a
terminal UI. It exists because **AI agents are first-class users of skulk** (A15), not
because tests needed a seam. Agents already fit the product's model — no accounts, no
CAPTCHA, random usernames, a JSON protocol — so this promotes an accidental capability to
a promise.

Two consequences follow, and they are the whole point of the document:

- **This interface is versioned and its breaking changes are breaking releases.** It is
  not a test harness detail to be refactored freely.
- **The test suite and agents consume the same contract.** The ExUnit integration suite
  IS the compatibility suite; if it passes, agents work.

## 2. Why the version is independent of the wire protocol

The wire protocol version moves on a schedule of its own: `v0` today, `v2` when OPAQUE
lands (M2), `v3` when messages become end-to-end encrypted (M3). **Agents should not have
to care about any of that**, and with this interface they do not.

The reason is that the client, not the agent, is the cryptographic endpoint. At M3 the
`chat.message` frame stops carrying `text` and starts carrying `nonce` + `ciphertext` — but
`skulk` decrypts before emitting anything, so the headless `message` event still carries a
plain `text` field. An agent written against headless v1 today keeps working through the
E2EE upgrade without a change, and gains E2EE for free.

That insulation is what A15's "independent version field" buys. `headless_version` changes
only when *this* interface changes.

---

## 3. Framing

- **One JSON object per line**, both directions. UTF-8. Lines end with `\n` (`0x0A`).
  A trailing `\r` is tolerated on input and never produced on output.
- **stdout carries nothing but this protocol.** Every line on stdout is a complete JSON
  object. An agent can pipe stdout straight into a JSON-per-line parser without filtering.
- **stderr carries human-readable diagnostics** — logs, usage errors, panics. Never parse
  it; its format is explicitly not promised (§11).
- **No pretty-printing, ever.** A JSON object never spans lines.
- Output is **flushed per line**. An agent blocking on a read is never waiting on a buffer.

### 3.1 Line size

| Direction | Limit |
| --- | --- |
| stdin (agent → skulk) | `65536` bytes per line |
| stdout (skulk → agent) | **unbounded** |

The asymmetry is deliberate and mirrors the wire protocol's decision D2. The inbound cap
bounds what a peer can make the client allocate. Outbound has no cap because it cannot: a
`joined` event carries the room's entire retained history, which spec §8 permits to reach
**4 MiB — on one line**.

> **Consumers: use an unbounded line reader.** Go's `bufio.Scanner` defaults to a 64 KiB
> limit and will silently stop; use `bufio.Reader.ReadString('\n')` or raise
> `Scanner.Buffer`. An Elixir `Port` in `{:line, n}` mode truncates at `n`; read in
> `:stream` mode and split on newlines yourself. Getting this wrong shows up as a
> mysteriously truncated `joined` on a busy room and nowhere else.

An over-long stdin line is answered with an `error` event (`invalid_command`); the client
discards bytes through the next newline and keeps running.

---

## 4. Startup

The **first line on stdout** is always `ready`, emitted before any network activity:

```json
{"event":"ready","headless_version":1,"protocol_version":0,"client_version":"0.1.0"}
```

`ready` announces the contract, not connectivity — the client has not connected to a relay
at this point and does not until a `create` or `join` command arrives. A harness or agent
should wait for `ready` before writing a command.

`client_version` is informational; its format is not promised (§11). Branch on
`headless_version`.

---

## 5. Commands

An agent writes command objects to stdin:

```json
{"id":"<optional>","command":"<name>","params":{}}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `command` | string | **yes** | One of §5.1–§5.5. |
| `params` | object | no | Defaults to `{}`. |
| `id` | string | no | Opaque, agent-chosen, ≤ `128` bytes. Echoed verbatim on the terminal response and on any `error` answering this command. |

`id` is **the agent's correlation handle and nothing else.** The client generates its own
wire `request_id` values (UUIDv4, per protocol v0 §4.3); the two never mix, and an agent
never sees a `request_id`.

**Ordering.** Commands are processed strictly in the order they arrive, and each produces
exactly **one** terminal response — a success event or an `error`. Responses never reorder
among themselves. Unsolicited events (§6) may interleave anywhere.

### 5.1 `create`

Creates a room and joins it.

```json
{"id":"c1","command":"create","params":{}}
```

| Param | Type | Required | Default |
| --- | --- | --- | --- |
| `room_id` | string | no | generated locally (spec §9.1: eight words) |
| `password` | string | no | generated locally (spec §9.2: six-word passphrase) |

Response:

```json
{"id":"c1","event":"created","data":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"lentil-quartz-harbor-dusk-maple-wren","username":"quiet-otter-42","sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","expires_at":"2026-08-25T14:03:11.000Z","participants":[{"sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","username":"quiet-otter-42"}]}}
```

**`password` is always returned**, whether generated or supplied. This is A15's explicit
requirement, and it is the whole reason headless `create` is usable unattended: a generated
passphrase that only appeared on a TUI would be unrecoverable by a program. The TUI's
confirm-you-copied-it loop (§9.2) and Enter-to-accept default (A5) **do not exist here** —
they are interaction design for humans, and a process has nothing to confirm.

The returned `password` is what the agent shares with its counterpart through whatever
trusted channel it has. It is a secret; see §9.

### 5.2 `join`

```json
{"id":"j1","command":"join","params":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"lentil-quartz-harbor-dusk-maple-wren"}}
```

Both params required. Response:

```json
{"id":"j1","event":"joined","data":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","username":"bright-fox-17","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","expires_at":"2026-08-25T14:03:11.000Z","participants":[{"sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","username":"quiet-otter-42"},{"sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","username":"bright-fox-17"}],"history":[],"snapshot_sequence":0}}
```

`history` is an array of `message` event `data` objects (§6.2), ordered by `sequence`
ascending. `snapshot_sequence` is the boundary: every message above it arrives as a live
`message` event. It is `0` when history is empty, never `null`.

Messages may appear both in `history` and as a live event around the boundary; **agents
MUST deduplicate by `message_id`** (spec §15).

`create` and `join` are mutually exclusive and once-only: a second `create` or `join` on a
running process is `already_joined`. One process, one room, one session.

### 5.3 `send`

```json
{"id":"s1","command":"send","params":{"text":"hello"}}
```

Response is immediate and **local**:

```json
{"id":"s1","event":"accepted","data":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846"}}
```

`accepted` means "handed to the relay", not "stored". The message is confirmed when a
`message` event arrives carrying the same `message_id` — that event has the relay-assigned
`sequence` and `received_at`, and it reaches the sender as well as everyone else (protocol
amendment A11).

That two-step is deliberate. The client generates `message_id` (protocol decision D10), so
the agent gets a correlation handle at send time, and **the round trip is exactly A1d's
self-suppression check**: an `accepted` whose `message` never arrives means the relay
dropped it. Agents get that integrity property for free, and at M4 two agents with a side
channel can automate the full `/checkpoint` comparison on top of it.

### 5.4 `who`

```json
{"id":"w1","command":"who","params":{}}
```

```json
{"id":"w1","event":"participants","data":{"participants":[{"sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","username":"quiet-otter-42"}],"participant_count":1}}
```

### 5.5 `quit`

```json
{"id":"q1","command":"quit","params":{}}
```

```json
{"id":"q1","event":"bye","data":{}}
```

The process then exits `0`. No `disconnected` event follows — `bye` is the clean-shutdown
signal, and emitting both would make an orderly exit indistinguishable from a failure.

**Closing stdin (EOF) is equivalent to `quit`**: the client emits `bye` (without an `id`)
and exits `0`. This is the shutdown path a supervising harness actually uses — an Elixir
`Port` closes stdin when the port closes — so it is specified rather than left to chance.

---

## 6. Events

Unsolicited events carry no `id`.

### 6.1 `connected`

```json
{"event":"connected","data":{"server":"wss://relay.example/v1/ws"}}
```

Emitted once, during `create`/`join`, **before** the `created`/`joined` response. It reports
the transport, not membership.

### 6.2 `message`

```json
{"event":"message","data":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","sender_username":"bright-fox-17","sequence":2,"received_at":"2026-08-20T14:07:52.418Z","text":"hello","self":false}}
```

`self` is `true` when this is the echo of a message this process sent (A11). Agents that
would otherwise reply to their own messages need this; it is derived locally from
`sender_id` and is not a wire field.

`sender_username`, `sequence`, and `received_at` are **relay-assigned metadata and are not
authenticated** (protocol §5.6). At M3 they will sit outside the AEAD. Do not treat
`sender_username` as an identity claim.

**At M3 this event does not change.** The wire will carry `nonce` + `ciphertext`; the client
decrypts and emits the same `text` field it emits today (§2).

### 6.3 `presence`

```json
{"event":"presence","data":{"action":"joined","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","username":"bright-fox-17","participant_count":2}}
```

`action` is `"joined"` or `"left"`. One event type with an action field rather than two
event types, so an agent filters on `event` once. `participant_count` is the count *after*
the change.

### 6.4 `room_expired`

```json
{"event":"room_expired","data":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","expired_at":"2026-08-25T14:03:11.000Z"}}
```

The room's inactivity TTL elapsed (spec §14). The process exits `4` immediately after.

### 6.5 `disconnected`

```json
{"event":"disconnected","data":{"reason":"connection closed by relay"}}
```

The transport dropped unexpectedly. The process exits `3`. **There is no reconnect**: spec
§20 makes reconnection a fresh join with a new identity and a new username, so silently
reconnecting would misrepresent continuity. An agent that wants to rejoin starts a new
process and issues `join` again.

### 6.6 `error`

```json
{"id":"j1","event":"error","data":{"source":"wire","code":"authentication_failed","message":"authentication failed","fatal":true}}
```

| Field | Meaning |
| --- | --- |
| `source` | `"wire"` — a relay error code, exactly protocol v0 §6's ten. `"client"` — raised locally, from §7.2's list. |
| `code` | Stable, machine-readable. **Branch on this.** |
| `message` | Human-readable. Carries no machine meaning and may change at any time. |
| `fatal` | `true` when the process is about to exit; the exit code follows §8. |
| `id` | Present iff this answers a command that carried one. |

---

## 7. Error codes

### 7.1 Wire codes (`source: "wire"`)

Exactly protocol v0 §6's ten: `room_not_found`, `room_already_exists`,
`authentication_failed`, `room_expired`, `room_full`, `message_too_large`,
`invalid_message`, `unsupported_protocol_version`, `unsupported_frame_type`,
`internal_error`. They are relayed unchanged — the client does not reinterpret them.

### 7.2 Client codes (`source: "client"`)

| Code | Meaning | Fatal |
| --- | --- | --- |
| `invalid_command` | Malformed JSON, unknown `command`, missing or wrong-typed `params`, or a stdin line past `65536` bytes. | no |
| `not_joined` | `send`, `who`, or `quit`-scoped work before `create`/`join` succeeded. | no |
| `already_joined` | A second `create` or `join`. | no |
| `transport` | Could not reach the relay: DNS, refused, TLS failure, rejected upgrade. | yes |

`send` and `who` before joining fail locally with `not_joined` and never touch the network.

### 7.3 Which errors end the process

**Before a session exists, `create` and `join` failures are fatal.** The `error` event is
emitted with `fatal: true`, then the process exits per §8. One process is one join attempt;
retry and backoff belong to the agent, which is also what spec §20's reconnect-is-a-fresh-join
rule implies.

*This is deliberately stricter than the wire.* Protocol v0 keeps the connection open after
`authentication_failed` so a human can retype a password. A process has no one to ask, and
leaving it running would give an agent a hung handle with no path forward.

**After a session exists, errors are recoverable.** A `send` rejected with
`message_too_large` is an `error` event with `fatal: false`; the process keeps running and
the session is intact. Only `room_expired` (§6.4) and `disconnected` (§6.5) end it.

`invalid_command` is never fatal, at any point. Agents mistype; one bad line should produce
a diagnosis, not a dead process.

---

## 8. Exit codes

Mapped from spec §17.

| Exit | Cause |
| --- | --- |
| `0` | `quit`, or stdin EOF |
| `1` | any other failure |
| `2` | command-line usage error (including `--password`; see §9) |
| `3` | network/transport failure — `transport`, `disconnected` |
| `4` | `room_not_found`, `room_expired` (including the `room_expired` event) |
| `5` | `authentication_failed` |
| `6` | `room_full`, `server_capacity` |
| `7` | `unsupported_protocol_version` |

---

## 9. Secrets

**Passwords enter this process on stdin, as JSON, and by no other route.**

- **Never argv.** Process listings are world-readable on most systems and shell history
  persists (spec §20). `skulk --headless --password …` is a **usage error**: the client
  exits `2` with a human-readable message **on stderr**, having written nothing to stdout.
  The stdout-is-only-JSON promise holds because stdout stays empty.
- **Never environment variables.** They are inherited by children and visible in
  `/proc/<pid>/environ` on Linux.
- **Never logged**, on stderr or anywhere else — not the password, not its length, not a
  prefix. `--debug` does not relax this.
- **Never stored.** No client-side persistence (spec §9.2, §20).
- **Exact bytes.** Never trimmed, never Unicode-normalized. A trailing space is part of the
  password.

The one place a password appears on **stdout** is the `created` response (§5.1), which is
required: a generated passphrase no program can read is a passphrase that cannot be shared.
An agent handling that value is handling a secret, and everything above applies to it —
including keeping it out of the agent's own logs.

Relay URLs are **not** secrets and travel normally via `--server` or `SKULK_SERVER`
(spec §7.2). Remote relays must be `wss://`; plain `ws://` is refused unless the host is a
loopback address or `--allow-insecure` is passed.

---

## 10. Size limits

| Limit | Value | Source |
| --- | ---: | --- |
| `text` in `send` | `4096` UTF-8 **bytes** | spec §8 |
| stdin line | `65536` bytes | §3.1 |
| `id` | `128` bytes | §5 |

**The 4,096-byte message cap applies to agents exactly as it does to humans** (A15).
Structured payloads larger than that chunk at the application layer — the agent splits and
reassembles; skulk does not. This is a known constraint, recorded rather than worked
around, and it is revisited only if real agent usage demands it, not speculatively.

The bound counts **bytes**, not characters: `"🦊"` is four. The client does not
pre-validate it — the text goes to the relay and the relay's `message_too_large` is
relayed back, so there is exactly one implementation of the rule (protocol v0 rule V13)
rather than two that can disagree.

---

## 11. What is NOT promised

Everything not specified above may change in any release, including a patch release:

- **TUI behavior.** The interactive client is a separate surface with no compatibility
  relationship to this one.
- **stderr.** Format, verbosity, ordering, and whether a given line appears at all.
- **`message` text of `error` events.** Branch on `code`; never on `message`.
- **JSON key order**, and whitespace within a line.
- **Timing.** How long a command takes, and how unsolicited events interleave with command
  responses. The only ordering guarantees are the two in §5: commands are processed in
  order, and each has exactly one terminal response.
- **`client_version` format.**
- **Relay-assigned values.** `username`, `sender_id`, `sequence`, and `received_at` are
  chosen by the relay; only their *shapes* are specified (protocol v0 §4).
- **Additional fields and event types.** New ones may appear at any time — see §12.

---

## 12. Compatibility

`headless_version` is `1`. It changes only when this interface changes, never because the
wire protocol moved (§2).

**Additive changes are not breaking**, and are permitted in any release: new event types,
new fields on existing events, new commands, new optional params, new `client` error codes.

For that to hold, **agents MUST ignore unknown fields and unknown event types.** An agent
that rejects an event it does not recognize will break on a routine release. (This mirrors
protocol v0's decision D3, which pins the same rule one layer down.)

**Breaking changes** — removing or renaming a field, event, or command; changing a field's
type; changing an exit code's meaning; tightening a limit — require a `headless_version`
bump and are **breaking releases**, not refactors. A15 makes that a product promise rather
than a convention.

---

## 13. Transcript: two agents holding a conversation

Agent **A** creates a room; agent **B** joins with the password A returns; they exchange
messages and quit. This is the conversation the ExUnit harness (ROJ-35) replays and the
fixture ROJ-33 tests against.

`A>` / `B>` are lines written to that process's **stdin**; `A<` / `B<` are lines read from
its **stdout**. Both processes were started as `skulk --headless --server wss://relay.example`.

**Matching is shape-for-shape, not byte-for-byte.** `username`, `sender_id`, `sequence`,
`received_at`, `message_id`, and the generated `password` are chosen at runtime — by the
relay or by the client — so a harness asserts structure and field shapes (protocol v0 §4
patterns), not these literal values. Where a value must match *across* processes, the
transcript notes it.

```text
A< {"event":"ready","headless_version":1,"protocol_version":0,"client_version":"0.1.0"}
A> {"id":"c1","command":"create","params":{}}
A< {"event":"connected","data":{"server":"wss://relay.example/v1/ws"}}
A< {"id":"c1","event":"created","data":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"lentil-quartz-harbor-dusk-maple-wren","username":"quiet-otter-42","sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","expires_at":"2026-08-25T14:03:11.000Z","participants":[{"sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","username":"quiet-otter-42"}]}}

# A hands room_id and password to B out of band. In the harness that is a variable;
# between real agents it is whatever trusted channel they share.

B< {"event":"ready","headless_version":1,"protocol_version":0,"client_version":"0.1.0"}
B> {"id":"j1","command":"join","params":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"lentil-quartz-harbor-dusk-maple-wren"}}
B< {"event":"connected","data":{"server":"wss://relay.example/v1/ws"}}
B< {"id":"j1","event":"joined","data":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","username":"bright-fox-17","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","expires_at":"2026-08-25T14:03:11.000Z","participants":[{"sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","username":"quiet-otter-42"},{"sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","username":"bright-fox-17"}],"history":[],"snapshot_sequence":0}}

# A learns B arrived.
A< {"event":"presence","data":{"action":"joined","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","username":"bright-fox-17","participant_count":2}}

A> {"id":"s1","command":"send","params":{"text":"hello from agent A"}}
A< {"id":"s1","event":"accepted","data":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846"}}

# Both see the same message. A's copy carries self:true and the SAME message_id it was
# handed in `accepted` — that pairing is the self-suppression check of §5.3.
A< {"event":"message","data":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846","sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","sender_username":"quiet-otter-42","sequence":1,"received_at":"2026-08-20T14:07:52.418Z","text":"hello from agent A","self":true}}
B< {"event":"message","data":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846","sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","sender_username":"quiet-otter-42","sequence":1,"received_at":"2026-08-20T14:07:52.418Z","text":"hello from agent A","self":false}}

B> {"id":"s2","command":"send","params":{"text":"hello back from agent B 🦊"}}
B< {"id":"s2","event":"accepted","data":{"message_id":"1a4d6f08-5c2b-4e93-8d71-0f3a6b9c2e58"}}
B< {"event":"message","data":{"message_id":"1a4d6f08-5c2b-4e93-8d71-0f3a6b9c2e58","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","sender_username":"bright-fox-17","sequence":2,"received_at":"2026-08-20T14:07:53.102Z","text":"hello back from agent B 🦊","self":true}}
A< {"event":"message","data":{"message_id":"1a4d6f08-5c2b-4e93-8d71-0f3a6b9c2e58","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","sender_username":"bright-fox-17","sequence":2,"received_at":"2026-08-20T14:07:53.102Z","text":"hello back from agent B 🦊","self":false}}

A> {"id":"w1","command":"who","params":{}}
A< {"id":"w1","event":"participants","data":{"participants":[{"sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","username":"bright-fox-17"},{"sender_id":"u3Bk9QzR2mXvLp7TnAeYwQ","username":"quiet-otter-42"}],"participant_count":2}}

B> {"id":"q1","command":"quit","params":{}}
B< {"id":"q1","event":"bye","data":{}}
# B exits 0.

A< {"event":"presence","data":{"action":"left","sender_id":"Kd8vN2pQ7rT4xW9yZa3bLc","username":"bright-fox-17","participant_count":1}}

A> {"id":"q2","command":"quit","params":{}}
A< {"id":"q2","event":"bye","data":{}}
# A exits 0.
```

Note what is *not* in this transcript: no TTY, no prompts, no confirmation loops, no
passphrase shown to a human. Two processes with no terminal attached held a conversation —
which at M0 is, by construction, the first agent-to-agent conversation skulk supports.

### 13.1 An error path

```text
B< {"event":"ready","headless_version":1,"protocol_version":0,"client_version":"0.1.0"}
B> {"id":"j1","command":"join","params":{"room_id":"amber-river-copper-moon-forest-glass-harbor-star","password":"wrong-password-entirely"}}
B< {"event":"connected","data":{"server":"wss://relay.example/v1/ws"}}
B< {"id":"j1","event":"error","data":{"source":"wire","code":"authentication_failed","message":"authentication failed","fatal":true}}
# B exits 5.
```

And a recoverable one — note the process survives and the session is untouched:

```text
A> {"id":"bad","command":"snd","params":{"text":"typo in the command name"}}
A< {"id":"bad","event":"error","data":{"source":"client","code":"invalid_command","message":"unknown command \"snd\"","fatal":false}}
A> {"id":"s3","command":"send","params":{"text":"still here"}}
A< {"id":"s3","event":"accepted","data":{"message_id":"5e2b8c14-7a3d-4f06-b91e-4c8d0a2f6371"}}
```

---

## 14. Decisions

Points where A15 and the spec left room, decided here rather than left to the
implementation.

**H1 — `create`/`join` failures are fatal; post-session errors are not.** ROJ-33's
acceptance criteria require `--headless` to exit 5 on a wrong password, which the wire does
not force — protocol v0 keeps the connection open so a human can retype. A process has no
one to ask. One process is one join attempt; retry and backoff belong to the agent, which
matches §20's reconnect-is-a-fresh-join rule. See §7.3.

**H2 — EOF on stdin is `quit`.** Unspecified by A15, and unavoidable in practice: a
supervising process closes stdin to signal shutdown, and an Elixir `Port` does so when the
port closes. Treating EOF as anything else would make the harness's own shutdown path
undefined behavior.

**H3 — stdout lines are unbounded; only stdin is capped.** A `joined` event carries up to
4 MiB of history on one line (spec §8), so a symmetric cap would make a legitimate event
unrepresentable. The inbound cap survives because its job is bounding what a peer can make
the client allocate — the same asymmetry, and the same reasoning, as protocol v0's D2.

**H4 — `send` answers with `accepted`, and the `message` echo is the confirmation.** The
wire has no ack for `chat.send`; the A11 echo *is* the ack. Returning the client-generated
`message_id` (protocol D10) immediately gives the agent a correlation handle, and makes the
`accepted`-without-`message` case detectable — which is A1d's self-suppression check,
available to agents from M0 rather than M4.

**H5 — one `presence` event with an `action` field, not two event types.** Agents filter on
`event` once and switch on `action`, and a future `presence` variant is an additive `action`
value rather than a new event type an old agent would not recognize.

**H6 — `message` carries a client-derived `self` flag.** Not a wire field. Without it, every
agent independently reimplements "is this my own echo?" by comparing `sender_id` against the
one from its own `created`/`joined` — and an agent that gets it wrong replies to itself
forever. Cheap here, error-prone everywhere else.

**H7 — no client-side pre-validation of `text` length, `room_id`, or `password`.** The
values go to the relay and its error is relayed back. Protocol v0 rule V13 is the single
implementation of those bounds; a second copy in the client is a second thing to disagree.
Omitted `room_id`/`password` are *generated*, which is different from validated.

**H8 — the transcript is normative but matched by shape.** Relay-assigned values cannot be
reproduced byte-for-byte, so §13 defines the conversation's structure and field shapes.
It lives only in this document: a separate fixture file would be a second source of truth
with the same drift risk and no consumer that needs it, since both harnesses extract the
fenced block.

---

## 15. Change log

| Version | Date | Change |
| --- | --- | --- |
| 1 | 2026-08-20 | Initial specification (ROJ-30, milestone M0). |
