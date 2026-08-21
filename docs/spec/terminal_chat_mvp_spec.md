# Terminal E2EE Chat — MVP Build Specification

**Document status:** Ready for implementation  
**Version:** 1.1 — amendments A0, A3, A4, A5, A8, A10, A11, A12, A13, A15 folded in (see §28)  
**Product version:** MVP / protocol v1 (milestone M0 ships the plaintext walking skeleton on protocol v0)  
**Command name:** `skulk` (client), `skulkd` (relay) — A0  
**Implementation targets:** Elixir relay, Go client — A13  
**Reference project:** [Inkchat](https://github.com/byteHulk/inkchat) for terminal UX only

> This document is intended to be passed directly to an implementation agent. Implement the requirements as written. Do not add deferred features unless they are required to satisfy a stated acceptance criterion.

> **This specification is the single implementation authority.**
> `docs/designs/terminal-e2ee-chat.md` records how these decisions were reached and
> holds the amendments not yet due (A1, A2, A6, A7, A9, A14 — they fold at the
> milestone where their features land). Where the two differ on anything folded
> here, this document wins. Per §27, `docs/deviations.md` records only
> implementation-time deviations *from this version*.

## 1. Product summary

Build a minimal, terminal-based, text-only group chat application with end-to-end encryption (E2EE).

A user creates an unlisted room, chooses a shared password, and receives a random word-based room identifier. Another user joins by providing that identifier and the correct password. Everyone who knows the password joins immediately under a random username and can read all encrypted history still retained by the relay.

The relay stores room state and encrypted history in memory only. Rooms expire after five days without a successfully accepted chat message. Restarting the relay destroys every room.

The product has no accounts, persistent identities, attachments, database, moderation, approval workflow, kicking, banning, or application-level rate limiting.

## 2. Product principles

1. **Minimal interaction:** `create`, `join`, and chat should be enough to use the product.
2. **Honest privacy claims:** The relay cannot read message content, but it can observe connection metadata.
3. **No custom cryptography:** Use maintained implementations of standard cryptographic protocols and primitives.
4. **Ephemeral by construction:** The relay must not require or use persistent room storage.
5. **Self-hostable:** Anyone must be able to run their own relay from a published artifact. *(A13: the relay is a separate Elixir application, `skulkd`, distributed as a Docker image; the single-executable formulation is retired.)*
6. **Bounded memory:** Absence of rate limiting must not imply unbounded frames, rooms, participants, or history.

## 3. Goals

The MVP MUST provide:

- A terminal client for Linux, macOS, and Windows.
- A relay that can be publicly hosted or self-hosted.
- A separate room-creation command.
- Unlisted, high-entropy, word-based room identifiers.
- Password-protected rooms without accounts.
- Immediate admission after successful password authentication.
- Random usernames for every connection.
- End-to-end encrypted text messages.
- Encrypted room history stored only in relay memory.
- Complete retained history for every successfully authenticated participant.
- Automatic room expiration after configurable inactivity.
- Hard capacity and payload-size bounds.
- Clear documentation of security guarantees and limitations.
- **A documented, versioned machine interface** so that scripts and AI agents are
  first-class users rather than an accident of the design (A15).

## 4. Non-goals

The MVP MUST NOT include:

- User accounts, email addresses, phone numbers, or global profiles.
- Persistent or custom usernames.
- Join requests, approvals, denials, invitations, or waiting rooms.
- Creator, administrator, owner, or moderator roles.
- Kicking, banning, revocation, or membership credentials.
- Per-member keys, group epochs, MLS, forward secrecy, or post-compromise security.
- Selectable history policies or an `after-join` history mode.
- Manual room closing or password changes.
- Application-level rate limiting, CAPTCHA, IP reputation, or abuse scoring.
- Files, images, audio, video, reactions, threads, or rich previews.
- Direct/private messages.
- Message editing, deletion, search, or server-side content moderation.
- Public room discovery or a room directory.
- Persistent message or room storage.
- Federation, multiple-relay routing, P2P, WebRTC, or Tor integration.
- Browser, desktop GUI, or mobile clients.
- Claims that the implementation is audited or suitable for high-risk use.

## 5. Terminology

- **Client:** The terminal application used to create or join a room.
- **Relay:** The server that authenticates room-password knowledge, maintains live connections, and stores/forwards ciphertext.
- **Room ID:** An unlisted word-based locator. It is not the room password.
- **Room password:** A shared secret entered by all participants.
- **Room key:** A random 256-bit secret used to derive message-encryption keys. It is generated by the creator's client and never exposed to the relay.
- **OPAQUE record:** Server-side data used for password-authenticated key exchange. It is not the plaintext password or room key.
- **Key envelope:** The room key encrypted under a key derived from the client-only OPAQUE export key.
- **Participant:** Any connection that successfully authenticates to a room.
- **History:** Ciphertext messages retained in the relay's in-memory room state.

The words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.

## 6. Primary user experience

### 6.1 Create a room

```console
$ skulk create
Password (leave blank to generate): ********
Confirm password: ********

Room: amber-river-copper-moon-forest-glass-harbor-star
Joined as quiet-otter-42
Share the room ID and password through a trusted channel.
Type /help for commands.
```

Required behavior:

1. The client connects to the selected relay.
2. The client generates a room ID locally.
3. The client prompts for a password without echoing it. **The generated passphrase is
   the default and is shown above the prompt; pressing Enter accepts it, and typing a
   password of your own is the deliberate act (A5).**
4. If the user accepts the default, the client displays the generated passphrase once and
   asks the user to confirm they have copied it (§9.2).
5. For a user-entered password, the client asks for confirmation by retyping it. A
   mismatch re-prompts rather than aborting.
6. The client completes OPAQUE registration with the relay.
7. The client generates a random 32-byte room key.
8. The client encrypts the room key into a key envelope using the OPAQUE export key.
9. The relay atomically creates the room and stores the OPAQUE registration record and the key envelope **as separate fields** (see §13; the server-level OPAQUE setup secret is stored once per relay, not per room — A3).
10. The creator is authenticated into the room and receives a random username.

Room creation MUST fail cleanly if the generated ID already exists. The client MAY generate a replacement and retry up to three times before returning an error.

### 6.2 Join a room

```console
$ skulk join amber-river-copper-moon-forest-glass-harbor-star
Password: ********

Joined as bright-fox-17
Loaded 23 retained messages.
Type /help for commands.
```

Required behavior:

1. The client connects to the selected relay.
2. The relay returns `room_not_found` if the room does not exist.
3. The client prompts for the password without echoing it.
4. The client and relay perform OPAQUE login.
5. Incorrect passwords produce the generic result `authentication_failed`.
6. After successful authentication, the relay returns the encrypted room-key envelope.
7. The client derives the envelope-wrapping key from the OPAQUE export key and decrypts the room key locally.
8. The relay assigns a random username and a random connection-scoped sender ID.
9. The relay returns all retained ciphertext history in sequence order.
10. The client decrypts and displays the history, then enters live chat.

The `join` command MUST NOT create a missing room.

### 6.3 Chat session

Plain text entered without a leading `/` is sent as a chat message.

Supported in-room commands:

| Command | Behavior |
| --- | --- |
| `/help` | Display the supported commands and basic privacy note. |
| `/who` | Display random usernames currently connected to the room. |
| `/quit` | Leave the room and exit successfully. |

Unknown commands MUST display a local error and MUST NOT be sent as messages.

`Ctrl+C` MUST have the same user-visible result as `/quit`, except that a second `Ctrl+C` MAY terminate immediately.

### 6.4 Presence

- The relay assigns usernames after authentication.
- A username MUST be unique among connections currently in the same room.
- The recommended format is `<adjective>-<animal>-<two digits>`.
- Usernames are connection-scoped and change on every reconnect.
- Join and leave notices MUST be shown to connected participants.
- `/who` MUST return the current username list and participant count.
- Usernames and presence are metadata, not encrypted identity claims.
- **The relay MUST NOT assign a username that appears in retained history (A12).** §6.4
  guarantees uniqueness only among connected participants, so without this rule replayed
  history can show `bright-fox-17` while a different person is currently `bright-fox-17`.
  The client SHOULD also render replayed history distinctly from live messages.

## 7. Command-line interface

### 7.1 Top-level interface

```text
skulk create [OPTIONS]
skulk join <ROOM_ID> [OPTIONS]
skulk --headless [OPTIONS]
skulk --help
skulk --version
```

`serve` is deliberately absent: A13 moved the relay into a separate Elixir application
(`skulkd`) with its own distribution. `--headless` is the machine interface specified by
`docs/headless-v1.md` (A15).

### 7.2 Client options

```text
--server <URL>    Relay WebSocket URL
--no-color        Disable ANSI colors
--debug           Enable local diagnostic logs without secret/message logging
```

Server selection precedence, highest first:

1. `--server`
2. `SKULK_SERVER` environment variable

**There is no third rung (A10).** A build-time default public relay would mean advertising
an unauthenticated, unthrottled relay (§19 defers rate limiting) next to a one-liner
installer. skulk ships no default relay, so `--server` or `SKULK_SERVER` is required.

Remote relay URLs MUST use `wss://`. Plain `ws://` MUST be accepted only for loopback addresses unless the user explicitly passes `--allow-insecure`.

### 7.3 Headless mode — the machine interface

`skulk --headless` speaks newline-delimited JSON on stdin and stdout instead of drawing a
terminal UI. **Amendment A15 makes this a versioned product contract, not a test seam**: the
product serves both humans and AI agents, and agents already fit the model — no accounts, no
CAPTCHA, random usernames, a JSON protocol.

- The full contract is `docs/headless-v1.md`, versioned **independently of the wire protocol**.
  Breaking changes to it are breaking releases. The integration test suite consumes the same
  document agents do, so the tests are the compatibility suite.
- **Secrets flow only as JSON on stdin** — never argv (visible in process listings and shell
  history, which §20 already forbids), never environment variables.
- **Headless `create` returns the generated passphrase in its JSON response** and skips the
  human confirmation loops: §9.2's copy confirmation and A5's Enter-to-accept are TUI
  behaviours, and a process has nothing to confirm.
- §8's 4,096-byte plaintext cap applies to agents exactly as to humans. Structured payloads
  chunk at the application layer. Revisit only if real agent usage demands it, not
  speculatively.

### 7.4 Relay configuration

The relay is `skulkd`, a separate Elixir application (A13). It takes the same bounds as
configuration rather than as flags on the client:

```text
skulkd \
  [--bind <IP:PORT>] \
  [--room-ttl <DURATION>] \
  [--max-rooms <COUNT>] \
  [--max-members-per-room <COUNT>] \
  [--max-message-bytes <COUNT>] \
  [--max-history-messages <COUNT>] \
  [--max-history-bytes <COUNT>] \
  [--max-total-history-bytes <COUNT>]
```

The relay MAY rely on a reverse proxy for TLS termination. Production documentation MUST show a `wss://` deployment configuration.

## 8. Defaults and hard bounds

| Setting | Default |
| --- | ---: |
| Room inactivity TTL | `120h` |
| Maximum active rooms | `10,000` |
| Maximum connected participants per room | `32` |
| Maximum plaintext message size | `4,096` UTF-8 bytes |
| Maximum WebSocket frame size | `16,384` bytes |
| Maximum retained messages per room | `1,000` |
| Maximum retained encoded history per room | `4 MiB` |
| Maximum retained encoded history globally | `512 MiB` |
| Maximum room-ID length | `160` ASCII bytes |
| Maximum password length | `256` UTF-8 bytes |
| Minimum user-entered password length | `12` UTF-8 bytes |

These are capacity limits, not rate limits.

When a room reaches its per-room history limit, the relay MUST evict the oldest messages until both the message-count and byte-count limits are satisfied.

Before rejecting work due to a global capacity limit, the relay MUST purge expired rooms. If capacity remains exhausted:

- New room creation MUST fail with `server_capacity`.
- Existing room chat MUST fail with `server_capacity` if accepting the message would exceed the global history limit.
- The relay MUST NOT evict a non-expired room to admit another room.

## 9. Room identifiers and passwords

### 9.1 Room ID

- Generate eight independently selected words from a fixed 2,048-word list using a cryptographically secure random number generator.
- Join words with `-` and serialize them as lowercase ASCII.
- This provides 88 bits of identifier entropy.
- The word list and ordering MUST be versioned and shared by all clients.
- The room ID is a locator and MUST NOT be presented as a replacement for the password.
- Rooms MUST never appear in a public listing or discovery endpoint.

### 9.2 Password handling

- Password prompts MUST disable terminal echo.
- User-entered passwords MUST be confirmed during room creation.
- Treat the exact UTF-8 byte sequence as the password; do not silently trim or normalize it.
- Reject user-entered passwords shorter than 12 bytes or longer than 256 bytes.
- A blank creation password MUST generate a six-word passphrase from a fixed 7,776-word Diceware-style list using a cryptographically secure random number generator.
- Display a generated password once and ask the user to confirm that it has been copied before creating the room.
- Passwords MUST NOT be stored locally by the MVP.
- Passwords, OPAQUE export keys, room keys, and derived keys MUST NOT appear in logs, panic messages, telemetry, or error payloads.

## 10. Security model

### 10.1 Protected properties

With uncompromised clients and standard cryptographic assumptions, the MVP MUST protect message confidentiality and ciphertext integrity from:

- The relay operator.
- A passive network observer.
- A person who knows the room ID but not the password.

The relay MUST never possess the plaintext password, OPAQUE export key, room key, message key, or plaintext message.

### 10.2 Trusted properties

The relay is trusted for:

- Availability.
- Room existence reporting.
- Presence and random-username assignment.
- Enforcing connection-scoped sender IDs.
- Message ordering and delivery.
- Applying capacity bounds and expiration.

The relay can omit, delay, duplicate, reorder, or delete messages and can lie about presence. These behaviors are outside the MVP's cryptographic guarantees.

### 10.3 Explicit limitations

**The offline-recovery path, stated plainly (A4).** Anyone holding all three of a room's
**OPAQUE registration record**, its **key envelope**, and the **relay's OPAQUE server setup
material** (§13's `opaque_setup_secret`) can mount an offline dictionary attack on the room
password, recover the `export_key`, unwrap the room key, and decrypt every retained message.

The relay operator qualifies. So does a memory dump, a compromised host, or a seized
snapshot. **Against that party, confidentiality is exactly password strength.** A generated
six-word passphrase (~77 bits) makes the attack infeasible; a 12-byte user-chosen password
may not. This is why A5 makes the generated passphrase the default path. `SECURITY.md` MUST
state this with all three inputs named.

The MVP does not protect against:

- A participant sharing the password or decrypted content.
- A malicious participant forging content using the shared room key if the relay colludes or sender checks are bypassed.
- Screenshots, terminal capture, clipboard history, swap, core dumps, or a compromised endpoint.
- Password guessing against weak user-chosen passwords.
- Decrypting previously captured room ciphertext after later compromise of the room key.
- IP address, timing, room ID, participant-count, and approximate message-size observation by the relay.
- Traffic analysis.
- Denial of service.
- Server-side deletion or censorship.
- Guaranteed forensic deletion from operating-system or hardware memory.

The README and `/help` output MUST describe the implementation as experimental and unaudited.

## 11. Cryptographic design

### 11.1 Rules

- Do not design or implement a new PAKE, KDF, AEAD, hash, MAC, or random-number generator.
- Use an RFC 9807-compatible OPAQUE library.
- Prefer a library that has received independent review and pin an exact dependency version.
- Record the selected OPAQUE ciphersuite and dependency version in `SECURITY.md` and the protocol constants.
- If a maintained RFC 9807-compatible library cannot be integrated, stop and document the blocker; do not replace OPAQUE with a password hash sent to the relay.
- Use the operating system's cryptographically secure random-number generator.
- Erase secret buffers on a best-effort basis using a maintained zeroization library.

### 11.2 Room creation

1. Perform OPAQUE registration using the room ID as the credential identifier and the room password as the credential.
2. The creator client obtains the client-only OPAQUE `export_key`.
3. Generate `room_key` as 32 random bytes.
4. Derive a 32-byte `wrap_key`:

```text
wrap_key = HKDF-SHA-256(
  input_key_material = export_key,
  salt = UTF8(room_id),
  info = "skulk/v1/room-key-wrap"
)
```

5. Encrypt `room_key` with XChaCha20-Poly1305 under `wrap_key` using a random 24-byte nonce and this associated data:

```text
"skulk/v1/room-key/" || UTF8(room_id)
```

6. Store only the resulting nonce and ciphertext as the room-key envelope.

### 11.3 Room joining

1. Perform OPAQUE login against the room's stored record.
2. On success, the client obtains the same client-only `export_key`.
3. Derive `wrap_key` exactly as during creation.
4. Decrypt the stored key envelope locally to obtain `room_key`.
5. A key-envelope decryption failure MUST abort the join as `authentication_failed` and MUST NOT expose a more detailed remote error.

### 11.4 Message encryption

Derive a 32-byte message key once per joined client session:

```text
message_key = HKDF-SHA-256(
  input_key_material = room_key,
  salt = UTF8(room_id),
  info = "skulk/v1/messages"
)
```

For each message:

1. Generate a random UUIDv4 `message_id`.
2. Generate a random 24-byte XChaCha20-Poly1305 nonce.
3. Encode the exact UTF-8 message bytes as plaintext.
4. Construct associated data using the protocol library's length-prefixed binary encoding of:

```text
protocol_version
room_id
message_id
sender_id
```

5. Encrypt with XChaCha20-Poly1305 under `message_key`.
6. Send the header, nonce, and ciphertext to the relay.

The relay MUST verify that `sender_id` matches the authenticated WebSocket session before storing or forwarding the message.

Receiving clients MUST reconstruct the same associated data and reject messages whose authentication tag fails.

## 12. Architecture

**Amendment A13 replaced the Rust workspace with an Elixir relay and a Go client.** The
tolls were priced in the engineering review and are recorded here so an implementer does not
relitigate them.

```text
skulkd/          Elixir relay
skulk            Go client  (create · join · --headless)
```

### 12.1 Relay — `skulkd` (Elixir)

- **Bandit + Plug + the WebSock behaviour**: `GET /healthz`, `GET /v1/ws`.
- **No Phoenix Channels, no Phoenix.Presence.** Channels impose a second wire protocol on
  top of the one this document specifies and drag weakly-maintained Phoenix client
  libraries into the Go side; Presence is a multi-node CRDT for a problem a single-node
  in-memory relay does not have.
- **One `Skulkd.Room` GenServer per room**, under a `DynamicSupervisor` + `Registry`. The
  process is the concurrency control: §21's race-safety requirements are satisfied by
  serialisation in one process rather than by locks. Registry registration makes creation
  atomic — the §21 double-create race resolves as `{:error, {:already_started, _}}`.
- **Monitors, not heartbeats.** A member's connection process is monitored; `:DOWN` is the
  leave path, so an abrupt disconnect cleans itself up.
- **Scheduling behind a seam.** `Process.send_after/3` does not consult an injected clock,
  so the room takes both a clock and a timer abstraction — that is what makes §22.1's TTL
  boundary tests deterministic rather than slow.
- **Global history accounting via `:ets.update_counter` as an atomic reserve-then-undo**:
  increment by the encoded size and, if the total exceeds the cap, decrement and reject with
  `server_capacity`. Reservation semantics, not check-then-act.
- **OPAQUE (M2)** wraps `opaque-ke` in a rustler NIF on dirty CPU schedulers, because the
  BEAM has no RFC 9807 library. The NIF boundary is stateless — bytes in, bytes out, four
  pure functions — with `ServerLogin` state round-tripping as an opaque binary held by the
  connection process and treated as secret material.
- **Backpressure (§21)** is a mailbox-length check before each push, disconnecting a client
  over a documented bound. Documented honestly as a best-effort bound: `message_queue_len`
  is a snapshot and the socket buffers beyond it, so the guarantee is "runaway growth is cut
  off", not an exact byte ceiling.

### 12.2 Client — `skulk` (Go)

- **bubbletea** for the TUI; `--headless` for the machine interface (§7.4, A15).
- **`bytemare/opaque`** (RFC 9807, RFC-author-maintained) for the client side of M2.
- **`x/crypto`** XChaCha20-Poly1305 and HKDF.
- All AEAD, fold, and checkpoint code is client-only, so §11.4's canonical AAD encoder has a
  single implementation and no cross-language encoding problem exists.
- **Zeroization is degraded honestly (§11.1).** The Go client zeroes key slices explicitly,
  best-effort under GC; the BEAM cannot zeroize at all, and `SECURITY.md` must say so
  plainly given §10.3's offline-recovery path.

### 12.3 What this costs

The wire protocol is now the only thing holding the two implementations together, which is
why §16.3's golden corpus exists and why it is enforced in CI on both sides. Two codecs that
agree because a test says so is a weaker guarantee than one codec — the corpus is how that
gap is closed.

Inkchat MAY be consulted for terminal interaction patterns. Do not copy its
participant-hosted topology, default password, or shared-password key derivation. If any
Inkchat source is reused, preserve all required MIT notices.

## 13. Relay data model

The relay MUST keep an in-memory structure equivalent to:

```text
ServerState
  opaque_setup_secret
  rooms: Map<RoomId, Room>
  total_history_bytes

Room
  id
  opaque_registration_record
  encrypted_room_key_envelope
  created_at
  last_message_at
  next_sequence
  participants: Map<SenderId, Participant>
  history: Deque<StoredMessage>
  history_bytes

Participant
  sender_id
  random_username
  connected_at
  websocket_handle

StoredMessage
  protocol_version
  message_id
  sender_id
  sender_username
  nonce
  ciphertext
  sequence
  received_at
  encoded_size
```

`sender_username` is captured at store time (**A8**). §16.4 requires it on forwarded
messages and usernames are connection-scoped (§6.4), so without capturing it here, history
replayed to a later joiner has no attributable sender for any participant who has since
disconnected. It is unauthenticated relay metadata, outside the AAD, and it counts toward
`encoded_size` and therefore toward §8's history byte accounting.

No room field may contain the plaintext password, room key, message key, or plaintext message.

The OPAQUE server setup secret MAY be generated at relay startup because all room records are also intentionally lost at restart.

## 14. Room lifecycle

Room states are:

```text
nonexistent -> creating -> active -> expired/deleted
```

- Room creation MUST be atomic. A partially completed registration MUST NOT leave a joinable room.
- `created_at` initializes room activity.
- Only a stored chat message sent by an authenticated participant updates `last_message_at`.
- Joins, leaves, failed authentication, `/who`, ping/pong, and presence events MUST NOT refresh the room TTL.
- An active connection does not prevent expiration.
- On expiration, disconnect participants with `room_expired`, erase the room from memory, and release its history accounting.
- A periodic cleanup task SHOULD run at least once per minute.
- Every room lookup MUST also lazily check expiration so correctness does not depend on cleanup scheduling.
- Process shutdown or crash naturally deletes all room state. The server MUST NOT reload rooms at startup.

## 15. History behavior

- History consists only of stored encrypted chat messages.
- Presence and system notices MUST NOT be retained as room history.
- A successful join receives a snapshot of every retained message ordered by `sequence` ascending.
- Live messages received during snapshot delivery MUST not be lost. Use a snapshot boundary sequence and then deliver later messages.
- Clients MUST deduplicate by `message_id` within the current process.
- When enforcing per-room caps, evict oldest messages before appending the new message.
- If one encoded message alone exceeds the configured history byte cap, reject it as `message_too_large`.
- There is no client-side disk history. Leaving or terminating the client clears its in-memory transcript.

## 16. Wire protocol

### 16.1 Transport

- WebSocket endpoint: `/v1/ws`.
- Health endpoint: `GET /healthz`, returning only service health and protocol version.
- Use JSON text frames in protocol v1.
- Binary WebSocket frames MUST be rejected with `unsupported_frame_type`.
- Every frame MUST contain `v` and `type`.
- Unknown versions MUST produce `unsupported_protocol_version`.
- Unknown fields MAY be ignored for forward compatibility.
- Missing, malformed, oversized, or invalid fields MUST produce a structured error and close the connection when continued parsing would be unsafe.

### 16.2 Common envelope

```json
{
  "v": 1,
  "type": "chat.send",
  "request_id": "optional UUIDv4",
  "payload": {}
}
```

### 16.3 Required protocol operations

The protocol MUST support:

- `create.begin`
- OPAQUE registration request/response/finalization frames
- `create.commit` containing the encrypted room-key envelope
- `join.begin`
- OPAQUE login request/response/finalization frames
- `join.complete`
- `history.snapshot`
- `chat.send`
- `chat.message`
- `presence.joined`
- `presence.left`
- `presence.list`
- `room.expired`
- `ping`
- `pong`
- `error`

OPAQUE payload bytes, nonces, and ciphertext MUST be encoded as unpadded Base64URL strings in JSON.

**The relay MUST deliver `chat.message` to the originating session (A11).** §16.3 lists the
frame types without stating the broadcast set. The sender needs its own message back, with
the relay-assigned `sequence`, for the M4 integrity layer to work at all: without the echo a
sender's transcript omits its own messages while every other client includes them, so every
continuity code mismatches on an honest relay. The echo is byte-identical to every other
member's copy.

**Schema authority (A13).** The stack is two independent implementations in two languages,
so there is no shared crate to hold the schemas. Instead a **versioned golden frame corpus**
lives in the repository (`docs/protocol/corpus/`): valid and invalid frames per type, each
invalid one annotated with the error code it must produce. Both test suites walk it and must
accept and reject every vector identically, or CI fails. The corpus IS the exact-schema
documentation this section requires, and it seeds §22.3's fuzzing.

### 16.4 Stored and forwarded chat message

The logical message fields are:

```text
v:                 1
room_id:           string
message_id:        UUIDv4
sender_id:         128-bit random Base64URL value
sender_username:   server-assigned string
nonce:             24 bytes, Base64URL
ciphertext:        Base64URL
sequence:          server-assigned u64
received_at:       server-assigned RFC 3339 UTC timestamp
```

`sender_username`, `sequence`, and `received_at` are relay-provided metadata and are not included in the encrypted plaintext. All three are stored with the message (§13, A8) so that replayed history attributes correctly after the sender disconnects.

## 17. Errors and exit behavior

Errors MUST have stable machine-readable codes and human-readable messages.

Required codes:

| Code | Meaning |
| --- | --- |
| `room_not_found` | No active room exists for the supplied ID. |
| `room_already_exists` | Creation collided with an existing room. |
| `authentication_failed` | Password login or key-envelope recovery failed. |
| `room_expired` | The room expired during or before the operation. |
| `room_full` | The participant cap is reached. |
| `message_too_large` | Plaintext/ciphertext/frame exceeds a configured bound. |
| `server_capacity` | A global room or history capacity is exhausted. |
| `invalid_message` | The submitted frame or field is invalid. |
| `unsupported_protocol_version` | Client and relay protocol versions do not overlap. |
| `unsupported_frame_type` | A binary WebSocket frame was received. |
| `internal_error` | An unexpected relay failure occurred. |

Suggested process exit codes:

```text
0  normal exit
2  command-line usage error
3  network/transport error
4  room not found or expired
5  authentication failed
6  server capacity or room full
7  protocol incompatibility
1  all other failures
```

Remote errors MUST NOT contain stack traces, secret material, or internal dependency details.

## 18. Logging and privacy

### 18.1 Relay logging

The relay MAY log:

- Startup, shutdown, and configuration excluding secrets.
- Counts of active rooms, connections, and retained ciphertext bytes.
- Error codes and protocol versions.
- Room creation/expiration events using a keyed or truncated room-ID digest rather than the full room ID.

The relay MUST NOT log:

- Passwords or password lengths.
- OPAQUE messages beyond aggregate error codes.
- Export keys, room keys, wrapping keys, message keys, nonces, or key envelopes.
- Ciphertext or plaintext message payloads.
- Full room IDs by default.
- Terminal input.

Access logging SHOULD be disabled by default. If a deployment proxy records IP addresses or request paths, deployment documentation MUST disclose that fact.

### 18.2 Client logging

- Normal operation MUST not create a log file.
- `--debug` logs only protocol states, event types, sizes, and sanitized errors to standard error.
- Debug output MUST never include message text or secret/key material.

## 19. No application-level rate limiting

This omission is intentional for MVP v1.

- Do not implement token buckets, per-IP attempt counters, cooldowns, CAPTCHA, or request quotas.
- Do implement the fixed capacity, frame-size, message-size, participant, room, and history bounds in this specification.
- Documentation MUST warn that an internet-facing relay without rate limiting is vulnerable to password guessing, room floods, connection floods, and denial of service.
- The project MUST be labeled experimental and not production-ready until basic abuse controls are added.

## 20. Local data behavior

- The client MUST NOT persist passwords, room keys, message keys, usernames, transcripts, or room membership.
- Command history integration MUST NOT record passwords because passwords are entered through a hidden interactive prompt, not command arguments.
- The client MAY persist a non-secret preferred relay URL only if explicitly configured by the user; environment-variable use is sufficient for MVP.
- A reconnect is a fresh join: prompt for the password, assign a new username, and fetch retained history again.

## 21. Concurrency and correctness

- Room creation, expiration, participant changes, sequence allocation, history insertion, and history eviction MUST be race-safe.
- Sequence numbers MUST be strictly increasing within a room.
- Two simultaneous creates for the same room ID MUST result in exactly one successful room.
- A join racing expiration MUST either join the still-active room or receive `room_expired`; it MUST NOT join a partially deleted room.
- A message racing expiration MUST either be stored and refresh the TTL or fail with `room_expired`.
- Slow clients MUST not block a room's broadcast loop indefinitely. Use bounded outbound queues and disconnect clients that cannot keep up.
- Backpressure queue sizes are capacity bounds and MUST be configurable or documented constants.

## 22. Testing requirements

### 22.1 Unit tests

Cover at minimum:

- Room-ID generation format and collision retry behavior.
- Password validation and generated-passphrase format.
- Random username format and room-local uniqueness.
- Key derivation domain separation.
- Room-key envelope round trip and failure with the wrong export key.
- Message encryption/decryption round trip.
- Authentication failure after header/AAD modification.
- Message-size calculations using UTF-8 byte length.
- History count and byte eviction.
- TTL boundary behavior using an injected/fake clock.
- Error-code serialization.
- Protocol frame validation and maximum sizes, driven by the golden corpus (§16.3) in
  **both** implementations, asserting identical accept/reject decisions and identical error
  codes.

### 22.2 Integration tests

The integration suite is driven by the relay's test framework and orchestrates **real client
binaries** through their documented `--headless` interface (A13, A15) — so the suite doubles
as the compatibility suite for that interface.

Cover at minimum:

1. Start an isolated relay.
2. Create a room.
3. Join from a second client with the correct password.
4. Exchange messages in both directions.
5. Join a third client and verify complete retained history.
6. Verify a wrong password fails.
7. Verify a nonexistent room does not get created by `join`.
8. Verify random usernames are unique within the room.
9. Verify `/who` reflects joins and leaves.
10. Fill history and verify oldest-message eviction.
11. Reach participant capacity and verify `room_full`.
12. Advance the fake clock and verify expiration and disconnection.
13. Restart the relay and verify that the room no longer exists.
14. Capture relay-visible frames and verify that known plaintext, password, and room key are absent.
15. Verify remote `ws://` is rejected by default while loopback `ws://` works.

### 22.3 Robustness tests

- Fuzz or property-test protocol frame decoding and canonical AAD encoding.
- Test malformed Base64URL, UUIDs, UTF-8, lengths, and unexpected frame types.
- Test abrupt client disconnects and relay shutdown.
- Test a slow consumer and bounded outbound queues.
- Run dependency vulnerability and license checks in CI.

No test may print secret material on failure.

## 23. Acceptance criteria

The MVP is complete only when all of the following are true:

- [ ] `skulk create` creates and joins an unlisted room, with the generated passphrase offered as the default (A5).
- [ ] `skulk join <room-id>` prompts for the password without echo and joins only when authentication succeeds.
- [ ] Two terminals can exchange Unicode text in real time.
- [ ] A joining client receives all retained encrypted history.
- [ ] Every connection receives a unique random username within its room.
- [ ] `/help`, `/who`, and `/quit` work as specified.
- [ ] The relay runs as `skulkd` from its published image and is selected with `--server` or `SKULK_SERVER`; there is no default relay (A10).
- [ ] A packet/frame capture at the relay contains no plaintext message, plaintext password, or room key.
- [ ] The relay source contains no path that receives or logs plaintext messages.
- [ ] The server stores no room or message state on disk.
- [ ] A relay restart removes every room.
- [ ] Rooms expire after the configured inactivity TTL even when clients remain connected.
- [ ] Only stored authenticated chat messages refresh the TTL.
- [ ] Message, frame, room, member, and history bounds are enforced.
- [ ] No join approval, moderation, kicking, admin, persistent identity, attachments, or rate-limiting feature is present.
- [ ] Unit, integration, and robustness tests pass in CI.
- [ ] Builds succeed for Linux, macOS, and Windows.
- [ ] `README.md`, `SECURITY.md`, self-hosting documentation, and protocol-v1 documentation exist.
- [ ] Documentation clearly labels the project experimental, unaudited, and unsuitable for high-risk use.

## 24. Required repository deliverables

The implementation must produce:

- The Elixir relay (`skulkd/`) and the Go client (`cmd/skulk`, `internal/`).
- The `skulk` binary with `create`, `join`, and `--headless`.
- Automated tests described above, including the golden frame corpus (§16.3) enforced in
  both languages and the ExUnit integration suite that drives real client binaries.
- `README.md` with quick start and privacy limitations, carrying the honesty notice
  required by §27 until end-to-end encryption actually ships.
- `SECURITY.md` with the threat model, the A4 offline-recovery path with all three inputs
  named, pinned crypto dependencies and versions, and vulnerability-reporting instructions.
- `docs/protocol-v0.md` (and its successors per version) with exact frame schemas, the
  validation order, limits, and the corpus that enforces them.
- `docs/headless-v1.md` with the machine interface (A15).
- `docs/self-hosting.md` with local, Docker, and TLS reverse-proxy examples.
- `Dockerfile` for the relay and minimal container configuration.
- Example environment/configuration file containing no secrets.
- CI for formatting, linting, tests, and dependency checks on both languages.
- An open-source license selected by the repository owner; MIT if none is supplied before
  the first public release.
- Attribution notices for any reused Inkchat source.

## 25. Implementation order — the milestone ladder

**This supersedes the earlier linear ordering, including its closing "do not begin optional
features" line.** The engineering review restructured delivery into a ladder that stands up a
working system first and layers security onto a living foundation. Ephemerality makes this
cheap: rooms never persist, so no milestone migrates data — each upgrade is a protocol
version bump affecting live clients only.

**Ladder-wide constraint:** every milestone uses the final frame envelope
(`{"v", "type", "request_id", "payload"}`). M0 carries a plaintext `text` field where M3 puts
`nonce` + `ciphertext`, so end-to-end encryption lands as a payload swap and a version bump,
never as a new protocol.

| Milestone | Protocol | Contents |
| --- | ---: | --- |
| **M0** Walking skeleton | `v0` | Relay, client, presence, history, TTL, room passwords via argon2id over `wss`. **Not encrypted, and the README must say so.** |
| **M1** Hardening | `v0` | §8's capacity bounds with reserve-then-undo accounting, history eviction, backpressure, `room_full` / `server_capacity`, A12 no-recycle, §22.3 fuzzing. |
| **M2** Real auth | `v2` | OPAQUE registration/login via the rustler NIF, gated on the cross-language interop spike. The relay stops seeing passwords. |
| **M3** End-to-end encryption | `v3` | Room-key generation and envelope, XChaCha20 messages with domain-separated AAD, A8 capture, zeroization. A frame-capture test proves no plaintext reaches the relay. |
| **M4** Integrity | `v3` | The continuity fold, contiguity check, and self-suppression check. |
| **M5** Distribution | `v3` | Release binaries, install one-liners, the relay image, and the full §23 acceptance suite. |

**§23's acceptance checklist is the M5 gate, not the M0 gate.**

## 26. Deferred backlog

The following may be considered only after MVP completion:

- Application-level rate limiting and abuse controls.
- Join requests and creator approval.
- Persistent room-specific member credentials.
- Admin keys, closing, kicking, and revocation.
- Per-member authenticated identities.
- Key rotation and MLS-backed membership epochs.
- Cryptographic `after-join` history isolation.
- Password rotation and recovery.
- Custom usernames.
- P2P transport and Tor support.
- Persistent encrypted history.
- Independent protocol and implementation security review.

## 27. Implementation-agent guardrails

- Keep the implementation within this scope.
- **Until end-to-end encryption actually ships, say so.** The README must state, above the
  fold, that the relay can read every message. This survives every README edit until the
  milestone that makes it false.
- Prefer explicit, readable code over generalized frameworks.
- Do not describe transport encryption alone as E2EE.
- Do not derive the room key directly from the password.
- Do not send a password hash or deterministic password-derived bearer value to the relay.
- Do not invent cryptographic constructions to work around a library integration problem.
- Do not log secrets or message content, including in tests.
- Do not silently add persistence.
- Treat capacity checks as mandatory even though rate limiting is deferred.
- Record every unavoidable deviation from this specification in `docs/deviations.md` before implementing it.

## 28. Changelog

### v1.1 — 2026-08-21

Ten amendments from `docs/designs/terminal-e2ee-chat.md` folded in. Each line is why the
amendment exists, not merely what it changed.

| # | Change | Why |
| --- | --- | --- |
| **A0** | The product is `skulk`; the relay is `skulkd`; `SKULK_SERVER`; HKDF info strings and the room-key AAD become `skulk/v1/…`. §1 header, §6, §7, §11.2, §11.4, §23. | Not a naming preference — the name is baked into cryptographic domain-separation constants, so it had to freeze before any of them could. |
| **A3** | §6.1 step 9 states that the OPAQUE registration record and the key envelope are separate stored fields, cross-referencing §13. | A reader of §11 alone concludes the envelope is all that persists, and then builds a relay that cannot authenticate anyone. |
| **A4** | §10.3 names the offline-recovery path with all three inputs required. | §10.3's generic "password guessing" line understated it: against anyone holding all three, confidentiality *is* password strength — which is the whole argument for A5. |
| **A5** | §6.1 inverts the create prompt: the generated passphrase is the default and Enter accepts it. | Makes the strong path the lazy path. Typing your own becomes the deliberate act. Both confirmations survive unchanged. |
| **A8** | §13's `StoredMessage` gains `sender_username`; §16.4 cross-references it. | A real spec bug: §16.4 required the field on forwarded messages, §13 had nowhere to keep it, and usernames are connection-scoped — so replayed history had no attributable sender for anyone who had left. |
| **A10** | §7.2 drops the build-time default relay; §23 follows. | Shipping one means advertising an unauthenticated, unthrottled relay next to a one-liner installer, while §19 defers rate limiting. |
| **A11** | §16.3 states the broadcast set: the relay delivers `chat.message` to the sender too. | Without the echo the sender's transcript omits its own messages while everyone else's includes them, so M4's continuity codes mismatch permanently on an *honest* relay. |
| **A12** | §6.4 forbids assigning a username present in retained history. | §6.4 guaranteed uniqueness only among connected participants, so replayed history could show a name a different person is currently using. |
| **A13** | §12 replaced entirely (Elixir relay + Go client); §2.5, §7.1, §7.3, §16.3, §22, §24, §25. §16.3's shared-crate rule becomes the golden frame corpus. | The stack changed, and with it the mechanism that keeps client and relay agreeing: two independent codecs need an enforced data contract where one crate used to suffice. |
| **A15** | New §7.3; §3 goals; §22.2. | Promotes an accidental capability to a promise: agents already fit this product's model, so the machine interface gets versioned and its breaking changes become breaking releases. |

**Not folded here.** A1, A2, A6, A7, A9, and A14 fold at the milestone where their features
land. Until then they live in the design document and are not requirements of this
specification.

**Also renumbered:** §7.3 is now Headless mode and relay configuration is §7.4.
