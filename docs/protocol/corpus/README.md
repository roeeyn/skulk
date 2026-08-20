# Golden frame corpus — protocol v0

This directory is the **cross-language contract** between the Go client (`internal/protocol`)
and the Elixir relay (`Skulkd.Protocol`).

Design amendment **A13** replaced the spec's shared-`protocol`-crate rule (§16.3) with two
independent codecs in two languages. What a shared crate gave for free — one implementation,
therefore one behaviour — has to be bought back some other way. These vectors are how: the
two implementations do not share code, so they must agree on **data**. Both test suites walk
this directory and must accept the same frames and reject the others **with the same error
code**. Disagreement is a CI failure, not a style difference.

The normative prose is [`docs/protocol-v0.md`](../../protocol-v0.md). Every vector cites the
rule from its §7 validation-order table that it exercises. **When the two disagree, the
document wins and the vector is the bug** — except when the document is silent, in which case
you have found something to add to its §10 Decisions.

## Layout

```
registry.json     frame types + directions, error codes, limits — the coverage source of truth
valid/*.json      frames both implementations MUST accept   (20 vectors)
invalid/*.json    frames both implementations MUST reject   (39 vectors)
```

## Vector file format

Every file in `valid/` and `invalid/` is one JSON object:

| Key | Type | Meaning |
| --- | --- | --- |
| `name` | string | Matches the filename without `.json`. |
| `description` | string | What this vector pins down. |
| `frame_type` | string \| null | The registry type, or `null` when the frame is too broken to have one (malformed JSON, binary). |
| `direction` | `"c2r"` \| `"r2c"` | Who sent it. |
| `receiver` | `"relay"` \| `"client"` | The role the validator runs as. Derived from `direction`; both are present so neither suite has to infer it. |
| `expect` | object | See below. |
| `wire` | object | How to reconstruct the exact bytes. See below. |
| `notes` | string | Optional. Why this vector exists — usually the mistake it catches. |

### `expect`

Valid vectors:

```json
{ "result": "accept" }
```

Invalid vectors:

```json
{ "result": "reject", "error_code": "message_too_large", "rule": "V13", "close": false }
```

- `error_code` — one of `registry.json`'s ten codes. **Assert exact equality.** "It rejected
  it somehow" is not the contract; identical codes across languages is the contract.
- `rule` — the `docs/protocol-v0.md` §7 rule that must fire. Several vectors exist *only* to
  pin rule ordering (`v-unsupported-with-unknown-type` is the clearest: it breaks two rules
  and the order decides the code). Suites are not required to assert `rule`, but a
  disagreement about it usually explains a disagreement about the code.
- `close` — whether the receiver must close the WebSocket after sending the error
  (`docs/protocol-v0.md` §7.1). Wire up this assertion when transport lands in ROJ-32/ROJ-33.

### `wire`

Exactly one of three shapes, because a corpus that only holds well-formed JSON cannot express
the failures that matter most:

| Shape | Bytes to feed the validator |
| --- | --- |
| `{"kind": "text", "json": <value>}` | The `json` value re-serialized as compact JSON. |
| `{"kind": "text", "raw": "<string>"}` | The UTF-8 bytes of `raw`, verbatim. |
| `{"kind": "text", "base64": "<b64>"}` | Standard base64 (padded), decoded. For byte sequences that are not valid UTF-8. |
| `{"kind": "binary", "base64": "<b64>"}` | Same decoding, delivered as a WebSocket **binary** frame. |

`kind` is the WebSocket frame type, and it is an input to validation, not a hint: rule V1
rejects every binary frame before anything is parsed. `invalid/binary-frame.json` carries the
bytes of a perfectly valid `ping` for exactly this reason.

**Use `raw` whenever the frame's byte length is what the vector is testing.** `json` is a
readability convenience and is re-serialized by each suite, so its exact length is not stable
across languages. `invalid/frame-oversized.json` is `raw` for this reason and is exactly
16,385 bytes — one past the limit.

## The seam both suites drive

```text
validate(receiver ∈ {relay, client}, kind ∈ {text, binary}, bytes) → ok | error_code
```

Two properties of this signature are load-bearing (`docs/protocol-v0.md` §7.3):

1. **It takes the receiver's role**, so the same corpus runs against both implementations.
2. **It covers every type in the registry in both roles.** The relay never legitimately
   receives a `chat.message`, but it must still reject one as a direction violation, and
   `invalid/direction-violation-chat-message-to-relay.json` asserts precisely that. A codec
   that validates only the frames its production path expects cannot run half this corpus.

## Consuming the corpus

### Go — `internal/protocol/protocol_test.go`

Corpus path is `../../docs/protocol/corpus`, relative to the package directory (Go tests run
with the working directory set to the package under test).

```console
go test ./internal/protocol/...
```

The seam is `newValidator(t)` in the test file. ROJ-29 shipped it as a `t.Fatalf` stub;
ROJ-33 replaced that one function body with an adapter over `protocol.Validate` and nothing
else in the file changed, which is what the seam was shaped for. A fourth pass asserts that
`protocol.Encode` round-trips every valid vector idempotently.

### Elixir — `skulkd/test/protocol_contract_test.exs`

Corpus loading lives in `skulkd/test/support/protocol_corpus.ex` (compiled via
`elixirc_paths` for `:test`), which reads
`Path.expand("../../../docs/protocol/corpus", __DIR__)` at compile time so each vector
becomes its own ExUnit test. It is shared: `protocol_contract_test.exs` walks the whole
corpus against the codec, and `transport_test.exs` replays the client-sent invalid
vectors over a real WebSocket.

```console
cd skulkd
mix test test/protocol_contract_test.exs    # the full corpus walk
mix test                                    # everything; no exclusions since ROJ-32
```

`Skulkd.Protocol.validate/3` returns `:ok` or `{:error, code}` with `code` an atom
(`:invalid_message`, …); the test compares `Atom.to_string(code)` against the vector's
`error_code`. Transport calls `decode/3` instead, which additionally returns the parsed frame
and a `close?` flag — the fourth pass asserts that flag against each vector's `close`
annotation.

### Both suites, same three passes

1. **Corpus integrity** — every file parses, every annotation is well formed, every
   `error_code` is in `registry.json`, every `rule` is a real rule, and every
   `(type, direction)` pair in the registry has at least one valid vector. *These assertions
   pass today.* They are what makes the codec failures below trustworthy: a red run means the
   codec is missing, not that the harness is broken.
2. **Valid vectors** — the validator accepts each one.
3. **Invalid vectors** — the validator rejects each one **with the annotated code**.

## Current state

**Both languages green.** `Skulkd.Protocol.validate/3` (ROJ-32) and `protocol.Validate`
(ROJ-33) accept and reject all 59 vectors identically, with identical codes.

That sentence is the point of this whole directory. Design A13 traded a shared Rust crate
for two independent codecs, and from ROJ-29 until now, "the two implementations agree" was a
promise. It is now a test that runs on every push — the first time A13's central claim is
enforced rather than asserted.

Each language adds one pass of its own on top of the shared three:

| | Extra pass |
| --- | --- |
| Elixir | `close?` matches each invalid vector's `close` annotation (transport needs it) |
| Go | `Encode(Decode(v))` is idempotent and re-decodes (the client re-emits frames) |

### The scaffolding that got here, and how it cleaned itself up

From ROJ-29 until each codec landed, plain `go test ./...` / `mix test` were **red on `main`
on purpose** — the red was the spec. CI (ROJ-37) gated on both halves of that bargain: a
green gate that skipped the pending tests, and a **must-still-be-red** gate asserting they
were still failing. The second kept the first honest — without it, the exclusion would have
been a place for real failures to hide.

It also made the scaffolding self-cleaning, and it fired exactly twice, as designed.
Implementing each codec turned its "must still be red" step into a failure whose message
named the marker to delete and told the author to remove the step; ROJ-32 and ROJ-33 each did
both in the same commit. **Nothing of it remains** — no tags, no prefixes, no CI steps — and
the gates are now plain `mix test` and `go test ./...`.

### What a real socket does and does not test

`transport_test.exs` replays every **client-sent** invalid vector over a live WebSocket and
asserts the same codes. Two vectors behave differently there, both correctly:

- **r2c vectors are not replayed.** A frame the *client* is supposed to receive, sent to the
  relay, is a direction violation (V11) — so it yields `invalid_message` rather than the code
  annotated for a client receiving it. The unit-level walk covers both roles; that is what
  the role parameter is for.
- **`bytes-not-utf8` never reaches the application.** The WebSocket protocol requires text
  frames to be valid UTF-8, so Bandit closes the connection with **1007** before `handle_in`
  runs. That is a *stronger* rejection than V3, not a gap: the frame never becomes a frame.
  The socket test asserts the connection dies; the unit walk still pins `invalid_message` for
  the codec itself.

## Changing the corpus

- Adding a frame type means: `registry.json`, a `valid/` vector per direction, a section in
  `docs/protocol-v0.md` §5, and — if it can fail in a new way — an `invalid/` vector.
- **A vector is never edited to match an implementation.** If a vector is wrong, fix it
  against the document and note why in the commit; if the document is wrong, amend it and its
  §10 Decisions in the same commit.
- Vectors that expire have a note saying so. `invalid/error-code-server-capacity.json` is the
  example: `server_capacity` becomes reachable at M1, at which point that vector is deleted
  and the code is added to `registry.json` in the same commit.
- At M1 this corpus seeds the property/fuzz suite (spec §22.3). Any mutation the fuzzer finds
  that the two implementations disagree on gets frozen here as a new vector.
