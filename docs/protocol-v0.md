# skulk wire protocol v0

**Status:** normative for milestone **M0** (walking skeleton).
**Source of truth for:** `docs/protocol/corpus/` (the golden frame corpus), `internal/protocol`
(Go client codec), `Skulkd.Protocol` (Elixir relay codec).
**Derived from:** `docs/spec/terminal_chat_mvp_spec.md` §16 (wire protocol) and §17 (error
codes), as amended by `docs/designs/terminal-e2ee-chat.md` A0, A8, A11, A12, A13, A15.

> **⚠️ v0 IS NOT ENCRYPTED.** Protocol v0 carries message plaintext in a `text` field. The
> relay reads every message. This is the M0 honesty gate (spec §27): v0 must never be
> described as private or end-to-end encrypted. E2EE arrives at M3 as a payload swap
> (`text` → `nonce` + `ciphertext`) and a version bump to v3.

---

## 1. Scope and the frozen envelope

The M0 ladder constraint (design doc, *Next Steps*) is that the **frame envelope is frozen
for the whole milestone ladder**:

```json
{ "v": 0, "type": "chat.send", "request_id": "…", "payload": {} }
```

Only `v` and the contents of `payload` change across M0 → M5. Nothing else in this document
is guaranteed to survive a version bump; the envelope is.

| Milestone | `v` | What changes |
| --- | ---: | --- |
| M0 | `0` | This document. Password over `wss`, plaintext `text`. |
| M2 | `2` | `create.begin` / `join.begin` payloads carry OPAQUE messages instead of `password`. |
| M3 | `3` | `chat.send` / `chat.message` carry `nonce` + `ciphertext` instead of `text`. |

M1 (hardening) adds no frame types and no fields; it adds the `room_full` and
`server_capacity` failure paths and stays on `v: 0`. `server_capacity` joined the
registry in ROJ-39, and ROJ-40 built the accounting that raises it: spec §8's room,
participant, and retained-history bounds.

### 1.1 What this document is not

It does not specify relay behaviour (room lifecycle, TTL, presence assignment, history
eviction) beyond what is observable on the wire. That lives in the spec (§13–§15) and in
ROJ-31 / ROJ-32. It does not specify the client's stdin/stdout machine interface — that is
`docs/headless-v1.md` (ROJ-30), which is versioned independently (A15).

---

## 2. Transport

- WebSocket endpoint: `GET /v1/ws`. Health endpoint: `GET /healthz`.
- The endpoint path stays `/v1/ws` across protocol versions; the *frame* version in `v` is
  what negotiates compatibility. (`/v1/` is the HTTP surface version, not the frame version.)
- **JSON text frames only.** A WebSocket **binary** frame is rejected with
  `unsupported_frame_type` and the connection is closed (spec §16.1, rule **V1**).
- One frame per WebSocket message. Frames are not batched, concatenated, or fragmented at
  the application layer.
- Every frame MUST be valid UTF-8 (rule **V3**) and a JSON **object** (rule **V4**).
- Remote relays MUST be reached over `wss://`. Plain `ws://` is permitted only for loopback
  addresses, and only when the client passes `--allow-insecure` (spec §7.2).

### 2.1 Frame size

| Bound | Value |
| --- | ---: |
| Maximum frame accepted **by the relay** (c→r) | `16384` bytes |
| Maximum frame accepted **by the client** (r→c) | *unbounded in v0* — see **D2** |

---

## 3. Envelope

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `v` | integer | **yes** | MUST be `0`. A JSON number with a fraction or exponent is not an integer. |
| `type` | string | **yes** | MUST be a member of the frame registry (§5). |
| `request_id` | string (UUIDv4) | per-frame | See §4.3 and the registry table. |
| `payload` | object | **yes** | Always present, even when empty (`{}`). |

**Unknown fields MUST be ignored** — both unknown envelope keys and unknown `payload` keys.
This is spec §16.1's "MAY be ignored" pinned to a MUST (**D3**): a corpus cannot contain an
optional behaviour. Corpus vector `valid/envelope-unknown-field.json` enforces it.

---

## 4. Primitive types and canonical representations

Every value below has exactly **one** accepted representation. Alternative spellings that a
lenient parser might accept (uppercase UUIDs, timestamps without milliseconds, offsets other
than `Z`) are invalid, because A1a's continuity fold at M4 requires that relay-supplied
metadata be byte-identical between a live `chat.message` and the same message replayed in a
history snapshot. Divergence there makes honest clients disagree.

| Name | Definition |
| --- | --- |
| `room_id` | `^[a-z]+(-[a-z]+){7}$` — exactly 8 lowercase-ASCII words joined by `-`, ≤ `160` bytes (spec §9.1). See **D4**. |
| `password` | UTF-8 string, `12`–`256` bytes inclusive. Exact bytes: never trimmed, never Unicode-normalized (spec §9.2). |
| `sender_id` | `^[A-Za-z0-9_-]{22}$` — 128 random bits, unpadded Base64URL (spec §16.4). Connection-scoped. |
| `username` | `^[a-z]+-[a-z]+-[0-9]{2}$`, ≤ `64` bytes (spec §6.4). Relay-assigned, connection-scoped, unauthenticated metadata. |
| `uuid4` | `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` — canonical lowercase UUIDv4, version nibble `4`, variant nibble in `[89ab]`. |
| `timestamp` | `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$` — RFC 3339 UTC, **exactly 3 fractional digits**, literal `Z`. No offsets, no other precisions. See **D5**. |
| `sequence` | integer, `1` ≤ n ≤ `9007199254740991` (2⁵³−1). Relay-assigned, strictly increasing, contiguous per room. See **D6**. |
| `text` | UTF-8 string, `1`–`4096` bytes inclusive (spec §8). **Bytes, not characters** — `"🦊"` is 4 bytes. Empty is invalid. |
| `count` | integer, `0` ≤ n ≤ 2⁵³−1. |
| `participant` | object `{ "sender_id": sender_id, "username": username }`. |
| `error_code` | string, one of the ten codes in §6. |
| `error_message` | UTF-8 string, `1`–`256` bytes. |

### 4.1 What is *not* validated at the wire layer

`sequence` contiguity, `message_id` uniqueness, username uniqueness, participant caps, and
room existence are **semantic** properties checked during processing, not schema properties.
A frame that is schema-valid may still be answered with `room_not_found`,
`authentication_failed`, `room_full`, `room_expired`, `room_already_exists`, or
`internal_error`. The golden corpus deliberately covers **only** the schema layer (§7.4).

### 4.2 Direction notation

`c→r` = client to relay. `r→c` = relay to client. A frame's direction set is a property of
its type (§5). Both codecs validate frames **as the receiving peer**.

### 4.3 `request_id` rules

| Rule | Applies to |
| --- | --- |
| **Required** on the request | `create.begin`, `join.begin`, `presence.list` (c→r), `ping` |
| **Required** on the response, echoing the request's value verbatim | `create.ok`, `join.ok`, `presence.list` (r→c), `pong` |
| **Optional** | `chat.send`, `error` — present on an `error` iff it answers a frame that carried one |
| **MUST be absent** | `chat.message`, `presence.joined`, `presence.left`, `room.expired` |

`chat.message` is the interesting case: **A11 requires the relay to deliver `chat.message`
to the originating session too**, and the identical frame goes to every member of the room.
A per-recipient correlation id in a broadcast frame would make the sender's copy differ from
everyone else's — which at M4 is precisely the divergence the continuity fold reports as
tampering. A sender correlates its own message by `payload.message_id`, which it generated.

---

## 5. Frame registry

Thirteen types. `Skulkd.Protocol` and `internal/protocol` MUST each implement validation for
**every type in both roles**, not only for the frames their production path receives — the
relay never receives `chat.message` in production, but its validator must still reject it as
a direction violation, and the corpus exercises exactly that.

| # | `type` | Direction | `request_id` | Payload |
| --: | --- | --- | --- | --- |
| 1 | `create.begin` | c→r | required | `{room_id, password}` |
| 2 | `create.ok` | r→c | echo | `{room_id, sender_id, username, expires_at, participants}` |
| 3 | `join.begin` | c→r | required | `{room_id, password}` |
| 4 | `join.ok` | r→c | echo | `{room_id, sender_id, username, expires_at, participants, history, snapshot_sequence}` |
| 5 | `chat.send` | c→r | optional | `{message_id, text}` |
| 6 | `chat.message` | r→c | absent | `{room_id, message_id, sender_id, sender_username, sequence, received_at, text}` |
| 7 | `presence.joined` | r→c | absent | `{sender_id, username, participant_count}` |
| 8 | `presence.left` | r→c | absent | `{sender_id, username, participant_count}` |
| 9 | `presence.list` | c→r | required | `{}` |
| 9 | `presence.list` | r→c | echo | `{participants, participant_count}` |
| 10 | `room.expired` | r→c | absent | `{room_id, expired_at}` |
| 11 | `ping` | c→r, r→c | required | `{}` |
| 12 | `pong` | c→r, r→c | echo | `{}` |
| 13 | `error` | r→c | optional | `{code, message}` |

`presence.list` is the one bidirectional request/response type (**D7**); `ping`/`pong` may
originate at either peer.

### 5.1 `create.begin` (c→r)

```json
{
  "v": 0,
  "type": "create.begin",
  "request_id": "3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",
  "payload": {
    "room_id": "amber-river-copper-moon-forest-glass-harbor-star",
    "password": "correct-horse-battery-staple-lentil-quartz"
  }
}
```

The client generates `room_id` locally (spec §6.1 step 2) and the relay creates the room
atomically. Answered by `create.ok`, or `error` with:

| Condition | Code |
| --- | --- |
| A room with that id already exists | `room_already_exists` |
| Password outside `12`–`256` bytes | `invalid_message` (rule V13) |
| Relay-side failure | `internal_error` |

`room_full` and `server_capacity` are M1 additions on this path. Both are live as of
ROJ-40: `server_capacity` when the active-room cap is reached (spec §8, after expired
rooms have been purged), and `room_full` when the room is at its participant cap.

### 5.2 `create.ok` (r→c)

```json
{
  "v": 0,
  "type": "create.ok",
  "request_id": "3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",
  "payload": {
    "room_id": "amber-river-copper-moon-forest-glass-harbor-star",
    "sender_id": "u3Bk9QzR2mXvLp7TnAeYwQ",
    "username": "quiet-otter-42",
    "expires_at": "2026-08-25T14:03:11.000Z",
    "participants": [
      { "sender_id": "u3Bk9QzR2mXvLp7TnAeYwQ", "username": "quiet-otter-42" }
    ]
  }
}
```

The creator is authenticated into the room by the same frame that creates it (spec §6.1 step
10), so `create.ok` carries the full session identity. `participants` contains exactly the
creator. There is no history, so — unlike `join.ok` — there are no `history` or
`snapshot_sequence` fields (**D8**).

`expires_at` is the room's current TTL deadline (spec §8 default `120h`). It is **advisory
and immediately stale**: only an accepted chat message refreshes the TTL (spec §14), and the
relay does not push refreshed deadlines in v0.

### 5.3 `join.begin` (c→r)

Payload is identical to `create.begin`. `join` MUST NOT create a missing room (spec §6.2).
Answered by `join.ok`, or `error` with:

| Condition | Code |
| --- | --- |
| No active room for that id | `room_not_found` |
| Wrong password | `authentication_failed` |
| The room expired during the join | `room_expired` |
| Participant cap reached (M1) | `room_full` |

An incorrect password yields the generic `authentication_failed` and nothing more (spec §6.2
step 5) — no hint about which of the room id or the password was wrong.

### 5.4 `join.ok` (r→c) — history snapshot semantics

```json
{
  "v": 0,
  "type": "join.ok",
  "request_id": "b57c1d84-0e6a-4f3b-9c2d-71ae83f04d6b",
  "payload": {
    "room_id": "amber-river-copper-moon-forest-glass-harbor-star",
    "sender_id": "Kd8vN2pQ7rT4xW9yZa3bLc",
    "username": "bright-fox-17",
    "expires_at": "2026-08-25T14:03:11.000Z",
    "participants": [ … ],
    "history": [ … ],
    "snapshot_sequence": 23
  }
}
```

`history` is an array of **`chat.message` payload objects** (§5.6) — payloads only, not
whole frames.

The snapshot rules (spec §15, and the boundary requirement it imposes):

1. `history` contains every message the relay still retains, ordered by `sequence`
   **ascending**. An array that is not sequence-ascending is invalid.
2. `snapshot_sequence` is the **boundary**: the `sequence` of the last message included, or
   `0` when `history` is empty. It is always present — never `null`, never omitted (**D9**).
3. Every message with `sequence > snapshot_sequence` reaches the joiner as a live
   `chat.message` frame. The relay MUST NOT drop messages accepted while the snapshot was
   being assembled: it picks the boundary, sends the snapshot, then delivers everything
   above it.
4. The client MUST deduplicate by `message_id` (spec §15), because rules 2 and 3 permit a
   message to arrive both inside the snapshot and as a live frame.
5. History is *messages only*. Presence events and system notices are never retained
   (spec §15), so they never appear here.
6. Replayed history is not distinguishable at the frame level from live traffic — the client
   knows the difference from the snapshot boundary, and SHOULD render it distinctly (A12).
7. `sender_username` in replayed history is captured at store time (A8), so history from a
   participant who has since disconnected still attributes correctly. Per A12 the relay MUST
   NOT assign a live participant a username that appears in retained history.

`join.ok` is the one frame that can be large: at the spec §8 caps, retained history reaches
**4 MiB**, far past the 16 KiB frame bound. See **D2** — that bound is inbound-only.

### 5.5 `chat.send` (c→r)

```json
{
  "v": 0,
  "type": "chat.send",
  "payload": {
    "message_id": "9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846",
    "text": "hello from the walking skeleton"
  }
}
```

The **client** generates `message_id` (**D10**). There is no `room_id`: a connection belongs
to exactly one room from the moment `create.ok` / `join.ok` is delivered, so the relay routes
by connection. A `chat.send` on a connection that has not joined is answered
`room_not_found`.

| Condition | Code |
| --- | --- |
| `text` empty or absent, `message_id` malformed | `invalid_message` |
| `text` > `4096` UTF-8 bytes | `message_too_large` |
| Whole frame > `16384` bytes | `message_too_large` |
| Encoded message alone exceeds the room's history byte cap (§15) | `message_too_large` |
| Not yet joined | `room_not_found` |
| Room expired | `room_expired` |
| Global retained history exhausted (§8) | `server_capacity` |

An accepted `chat.send` refreshes the room TTL. Nothing else does (spec §14).

### 5.6 `chat.message` (r→c)

```json
{
  "v": 0,
  "type": "chat.message",
  "payload": {
    "room_id": "amber-river-copper-moon-forest-glass-harbor-star",
    "message_id": "9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846",
    "sender_id": "Kd8vN2pQ7rT4xW9yZa3bLc",
    "sender_username": "bright-fox-17",
    "sequence": 24,
    "received_at": "2026-08-20T14:07:52.418Z",
    "text": "hello from the walking skeleton"
  }
}
```

`message_id` and `text` are the sender's. `sequence`, `received_at`, and `sender_username`
are relay-assigned metadata (spec §16.4 + A8) and are **not authenticated** — at M3 they sit
outside the AEAD, and at M4 the fold binds them only so that changes become *detectable*.

**A11 — the relay MUST deliver `chat.message` to the originating session**, byte-identical to
every other member's copy. This is not a convenience: at M4 the sender folds its own messages
using the relay-assigned `sequence` it can only learn from the echo, and A1d's
self-suppression check is exactly "did my own message come back to me." A relay that does not
echo makes every honest client's continuity code mismatch permanently.

At M3 this payload becomes `{room_id, message_id, sender_id, sender_username, sequence,
received_at, nonce, ciphertext}` — the same frame minus `text`.

### 5.7 `presence.joined` / `presence.left` (r→c)

```json
{ "v": 0, "type": "presence.joined",
  "payload": { "sender_id": "Kd8vN2pQ7rT4xW9yZa3bLc",
               "username": "bright-fox-17",
               "participant_count": 2 } }
```

Broadcast to the other members of the room. `participant_count` is the count **after** the
event. Presence is never retained as history (spec §15) and never refreshes the TTL (§14).

### 5.8 `presence.list` (c→r request, r→c response)

The wire form of `/who` (spec §6.3). Request payload is empty; the response carries the
current roster:

```json
{ "v": 0, "type": "presence.list",
  "request_id": "e4a91f7b-2c3d-4a58-9b06-8fd1c25e73a4",
  "payload": { "participants": [ { "sender_id": "…", "username": "…" } ],
               "participant_count": 2 } }
```

`participant_count` MUST equal `length(participants)`. Correlation is by `request_id`, which
is why it is required in both directions.

### 5.9 `room.expired` (r→c)

```json
{ "v": 0, "type": "room.expired",
  "payload": { "room_id": "amber-…-star", "expired_at": "2026-08-25T14:03:11.000Z" } }
```

Sent to every participant immediately before the relay disconnects them and erases the room
(spec §14). Unsolicited, so no `request_id`. A client that receives it exits with code `4`.

### 5.10 `ping` / `pong` (either direction)

Application-level liveness, independent of WebSocket control frames. Both payloads are empty.
`ping` carries a required `request_id`; the `pong` echoes it verbatim — that is the only
correlation available. Ping/pong MUST NOT refresh the room TTL (spec §14) and MUST NOT
appear in history.

### 5.11 `error` (r→c)

```json
{ "v": 0, "type": "error",
  "request_id": "3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",
  "payload": { "code": "authentication_failed", "message": "authentication failed" } }
```

`request_id` is present iff the frame being answered carried one. `message` is human-readable
and MUST NOT contain stack traces, secret material, password lengths, message text, or
internal dependency details (spec §17, §18). It carries no machine meaning — clients branch
on `code` only.

The relay MUST NOT send an `error` in response to an `error`. `error` is r→c only; a client
that sends one commits a direction violation (rule V11).

---

## 6. Error codes

The eleven codes of spec §17. Ten were reachable at M0; `server_capacity` was deliberately
left out of the registry until something could raise it, and ROJ-39 added it as M1's first
change — the corpus vector that asserted its absence was deleted in the same commit, which
is what its own notes instructed.

| Code | Meaning | Close connection |
| --- | --- | --- |
| `room_not_found` | No active room for the supplied id, or a room-scoped frame arrived before joining. | no |
| `room_already_exists` | `create.begin` collided with a live room. | no |
| `authentication_failed` | Password verification failed. Deliberately generic. | no |
| `room_expired` | The room expired before or during the operation. | yes |
| `room_full` | Participant cap reached (§8, default `32`). | no |
| `server_capacity` | A §8 global bound is exhausted — the active-room cap, or retained history across every room. Deliberately does not say which. | no |
| `message_too_large` | A frame or a `text` field exceeded a bound in §2.1 / §4, or one encoded message alone exceeded the room's whole history byte cap (§15). | frame-bound: yes; `text`- and history-bound: no |
| `invalid_message` | The frame or one of its fields is structurally invalid. | per rule (§7) |
| `unsupported_protocol_version` | `v` is not `0`. | yes |
| `unsupported_frame_type` | A binary WebSocket frame, or a `type` outside the registry. | binary: yes; unknown type: no |
| `internal_error` | Unexpected relay failure. Carries no detail. | no |

`chain_mismatch` (A1f) is a **client-local** condition at M4 and MUST NOT be added to this
table.

### 6.1 Exit codes

The client maps received codes to process exit codes (spec §17); `docs/headless-v1.md` is
normative for the machine interface.

| Code | Exit |
| --- | ---: |
| `room_not_found`, `room_expired` | `4` |
| `authentication_failed` | `5` |
| `room_full`, `server_capacity` | `6` |
| `unsupported_protocol_version` | `7` |
| transport failure (no frame received) | `3` |
| everything else | `1` |

---

## 7. Validation order

**This section is the cross-language contract.** A malformed frame usually violates several
rules at once; without a fixed order, Go and Elixir can both be "right" and still disagree
about which code to emit. Validation runs in this order and **stops at the first failure**.

| Rule | Check | Code on failure | Close |
| --- | --- | --- | --- |
| **V1** | The WebSocket frame is a **text** frame. | `unsupported_frame_type` | yes |
| **V2** | Frame size ≤ `16384` bytes. *Relay only* (**D2**). | `message_too_large` | yes |
| **V3** | Frame bytes are valid UTF-8. | `invalid_message` | yes |
| **V4** | Bytes parse as JSON, and the top-level value is an **object**. | `invalid_message` | yes |
| **V5** | `v` is present and is an integer. | `invalid_message` | yes |
| **V6** | `v` equals `0`. | `unsupported_protocol_version` | yes |
| **V7** | `type` is present and is a string. | `invalid_message` | yes |
| **V8** | `type` is in the §5 registry. | `unsupported_frame_type` | no |
| **V9** | `request_id` conforms to §4.3 for this type and direction, and — when present — is a canonical `uuid4`. | `invalid_message` | no |
| **V10** | `payload` is present and is a JSON object. | `invalid_message` | no |
| **V11** | This type is permitted **from** the peer that sent it (§5). | `invalid_message` | yes |
| **V12** | Every required payload field is present with the right JSON type. Unknown payload fields are ignored (§3). | `invalid_message` | no |
| **V13** | Every payload value satisfies its §4 pattern, range, and byte bound, and every cross-field invariant stated in §5 holds (`participant_count` == `len(participants)`; `history` sequence-ascending; `snapshot_sequence` == the last history `sequence` or `0`). | `invalid_message`, except `text` > `4096` bytes → `message_too_large` | no |

Notes on the ordering, all of which are load-bearing:

- **V1 before everything** — a binary frame has no text interpretation to validate.
- **V2 before V3** — a 20 MiB frame is rejected on size without being scanned for UTF-8
  validity or parsed. Size is the cheapest defence and must not be reachable past.
- **V6 after V5** — "`v` is missing/not a number" and "`v` is a version I do not speak" are
  different diagnoses and must not collapse into one code.
- **V6 before V8** — an unknown `type` under an unknown `v` reports the version, because
  `type` cannot be interpreted without knowing the version that defines it.
- **V9/V10 before V11** — envelope well-formedness is version-scoped and cheap; direction is
  a peer-role judgement.
- **V11 before V12** — a `chat.message` sent to the relay is a direction violation, not a
  payload-schema complaint, no matter how well-formed its payload is.
- **V13 last** — value bounds and cross-field invariants both presuppose that the fields
  exist with the right types, which is V12's job.

### 7.1 Closing the connection

Where the table says **close**, the receiver sends the `error` frame and then closes the
WebSocket, per spec §16.1's "close the connection when continued parsing would be unsafe."
The rules that close are those where the peer has demonstrated it is not speaking this
protocol (V1, V3, V4, V5, V6, V11), or where continuing would let it keep consuming
resources (V2). Recoverable per-frame mistakes (V8, V9, V10, V12, V13) do not close — an AI
agent that mistypes one frame should get a diagnosis, not a hang-up (A15).

`room_expired` also closes, but it is a lifecycle event, not a validation rule.

### 7.2 Ignoring unknown things is not laxity

V8 rejects unknown `type` values while §3 requires unknown *fields* to be ignored. These pull
in opposite directions on purpose: unknown fields are how a future version adds information
without breaking v0 readers, whereas an unknown `type` is a frame whose semantics are
entirely unknown and cannot be safely guessed.

### 7.3 Both roles, every type

Each implementation exposes one validator over the whole registry, parameterized by the role
of the **receiving** peer:

```text
validate(receiver ∈ {relay, client}, kind ∈ {text, binary}, bytes) → ok | error_code
```

Production code passes its own role. The contract tests drive both roles. This is why the
relay must be able to evaluate `chat.message` even though it never legitimately receives one.

### 7.4 The corpus covers V1–V13 only

Semantic outcomes (§4.1) depend on relay state and cannot be decided from bytes, so the
corpus never asserts them. `room_not_found`, `room_already_exists`, `authentication_failed`,
`room_expired` and `internal_error` are covered by ROJ-31 and ROJ-32 tests; `room_full`
and `server_capacity` by ROJ-40's.

---

## 8. Password handling on the wire

**A password appears in exactly two places in this protocol: the `payload.password` field of
`create.begin` and of `join.begin`.** Nowhere else, in either direction, at any milestone
before M2 removes it entirely.

Normative requirements (spec §9.2, §18, §20; A15):

- **Transport.** `create.begin` and `join.begin` MUST be sent only over `wss://`, or over
  `ws://` to a loopback address with `--allow-insecure` explicitly passed. The v0 password is
  a bearer secret in transit; TLS is the only thing protecting it.
- **Never in a URL.** Not in the WebSocket URL, not in a query string, not in a path segment,
  not in a header. URLs reach proxy logs, browser history, and referrer headers.
- **Never in argv or environment variables.** Process listings are world-readable on most
  systems and shell history persists (spec §20, A15). In `--headless` mode the password
  arrives only as a JSON value on stdin; the client MUST reject a `--password` flag.
- **Never logged.** Neither relay nor client may log the password, its length, its hash, or a
  prefix of it — on any code path, including panics, error payloads, and debug traces
  (spec §18.1). `--debug` does not relax this.
- **Never echoed back.** No relay→client frame contains a password field. `create.ok` and
  `join.ok` return session identity, never credentials.
- **Never stored.** No client-side persistence (spec §9.2, §20).
- **Exact bytes.** The password is the exact UTF-8 byte sequence the user supplied. No
  trimming, no case folding, no Unicode normalization. A trailing space is part of the
  password.
- **At rest on the relay (M0).** The relay stores only an argon2id hash (`argon2_elixir`,
  design A13), never the password. At M2 OPAQUE removes even the hash: the relay stops
  seeing passwords at all.
- **Error frames.** A failed login returns `authentication_failed` with a generic message.
  The `error` payload MUST NOT restate the submitted password, its length, or which field was
  wrong.

A password shorter than 12 or longer than 256 bytes is rejected at rule **V13** with
`invalid_message`, not `authentication_failed`. This leaks nothing: the bound is a published
constant, and no valid password can fall outside it.

> **v0's honest limit.** The relay receives the plaintext password inside the TLS session and
> hashes it there. A hostile or compromised relay sees it. That is the M0 bargain, and it is
> why M2 exists.

---

## 9. The golden frame corpus

`docs/protocol/corpus/` is the machine-readable form of this document and the **contract
between the two implementations** (design A13, replacing spec §16.3's shared-crate rule).
Both test suites walk it and must agree on every vector — accept the same frames, reject the
others with the *same error code*.

- `registry.json` — the frame-type registry, error codes, and limits, as data.
- `valid/*.json` — at least one vector per frame type and direction.
- `invalid/*.json` — one vector per failure mode, each annotated with the §7 rule it must
  trip and the §6 code that rule emits.
- `README.md` — the vector file format and how each suite consumes it.

Consumers today: `internal/protocol/protocol_test.go` (Go, ROJ-33) and
`skulkd/test/protocol_contract_test.exs` (Elixir, ROJ-32). Both currently fail: the corpus
and the harnesses exist, the codecs do not. That is the intended state at the end of ROJ-29.

The corpus also seeds M1's property/fuzz tests (spec §22.3) — valid vectors are mutation
seeds, and any mutation the fuzzer finds that the two implementations disagree on becomes a
new vector.

---

## 10. Decisions

Points where the spec was silent, ambiguous, or in tension with itself. Each was decided here
rather than deferred, per the SDD rule that the corpus cannot encode an open question.

**D1 — `unsupported_frame_type` covers both binary frames and unknown `type` values.**
Spec §16.1 mandates it for binary WebSocket frames and §17 glosses it as "a binary WebSocket
frame was received," which leaves an unknown `type` string with no natural code. Reading the
name for what it says — "I do not support this kind of frame" — covers both, and §16.1's MUST
is satisfied either way. A *known* type arriving from the wrong peer is different: the type is
supported, the sender is wrong, so that is `invalid_message` (V11).

**D2 — the 16,384-byte frame bound is enforced on frames received by the relay only.**
Spec §8 lists it as a capacity limit without a direction, and it collides head-on with §15:
retained history reaches 4 MiB, and `join.ok` carries a full snapshot. The bound exists to
stop a client from making the relay allocate arbitrarily, which is an inbound concern. ROJ-32
already states it as a transport-level inbound cap. Clients MUST NOT enforce a 16 KiB inbound
bound in v0. Client-side inbound bounds land in M1 alongside the rest of §8.

**D3 — "unknown fields MAY be ignored" (§16.1) is pinned to MUST be ignored.** A golden
corpus cannot contain a MAY: one implementation ignoring and the other rejecting would be two
"correct" readings with a red CI. Ignoring is the choice that makes M1–M3 additive.

**D4 — `room_id` is validated strictly as eight lowercase words.** Spec §9.1 is normative
about the shape, and a strict pattern keeps arbitrary-length attacker-chosen strings out of
the relay's registry keys. Consequence for downstream tickets: fixtures must use conforming
ids (`amber-river-copper-moon-forest-glass-harbor-star`), not `test-room`. ROJ-31's
concurrent-create race test feels this first.

**D5 — one timestamp representation: `YYYY-MM-DDTHH:MM:SS.sssZ`.** RFC 3339 permits offsets
and arbitrary fractional precision; A1a requires that `received_at` be byte-identical between
a live frame and the same message replayed from history, because both feed the M4 continuity
fold. Two spellings of one instant would make honest clients diverge. Fixing the format now
costs nothing; discovering it at M4 costs a protocol bump.

**D6 — `sequence` is capped at 2⁵³−1, not 2⁶⁴−1.** Spec §16.4 types it `u64`, but JSON
numbers are IEEE-754 doubles in most parsers, and a relay emitting 2⁶⁴−1 would be read back
as a different value in Go's `interface{}` path and in JavaScript tooling. At 4,096-byte
messages, 2⁵³ sequences is not a bound anyone reaches in an ephemeral room.

**D7 — `presence.list` is one bidirectional type, correlated by `request_id`.** Spec §16.3
lists `presence.list` as a single frame type without saying who sends it, and `/who` (§6.3)
needs a request. Inventing a `presence.query` type would add a frame the ticket's registry
does not list. The cost is that `presence.list` has a per-direction payload schema, which
`registry.json` carries explicitly.

**D8 — `create.ok` carries no `history` or `snapshot_sequence`.** A newly created room has no
history by construction, and an always-empty array invites a client to write one code path
that treats create and join as interchangeable, which they are not: `join.ok` has a snapshot
boundary to respect, `create.ok` does not.

**D9 — `snapshot_sequence` is `0` for an empty snapshot, never `null` or absent.** A single
always-present integer keeps both codecs' types non-optional and makes "is this message
inside the snapshot?" a plain comparison. `sequence` starts at `1`, so `0` is unambiguous.

**D10 — the client generates `message_id`.** The relay assigns `sequence`, `received_at`, and
`sender_username`; `message_id` is not in that set. At M3 the per-message AAD is
`protocol_version, room_id, message_id, sender_id` (A0), so the sender must know
`message_id` at encrypt time — before the relay has seen the frame. Deciding it now means M3
changes only the payload fields it must, and it gives the sender a correlation handle for the
A11 echo without a `request_id` in a broadcast frame.

**D11 — history in `join.ok` is inline, and there is no `history.snapshot` frame in v0.**
Spec §16.3 lists `history.snapshot` for v1; the M0 registry in ROJ-29 does not. Inline
history makes "authenticated with a consistent snapshot" a single atomic frame, which removes
the interleaving question v1 has to answer with a boundary protocol. If §8's caps make the
frame unwieldy at M1, chunking is an additive change to `join.ok`, not a new type.

**D12 — `chat.send` carries no `room_id`.** A connection is bound to exactly one room from
the moment `create.ok` / `join.ok` is delivered, so a client-supplied `room_id` would be
either redundant or a mismatch to adjudicate. `chat.message` *does* carry `room_id` because
it is stored (spec §16.4) and, at M3, it is an AAD input the receiver must have.

---

## 11. Change log

| Version | Date | Change |
| --- | --- | --- |
| v0 | 2026-08-20 | Initial specification (ROJ-29, milestone M0). |
