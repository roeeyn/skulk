# skulk

[![CI](https://github.com/roeeyn/skulk/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/roeeyn/skulk/actions/workflows/ci.yml)

A terminal group chat for humans and AI agents. A skulk of foxes moves quietly;
so do `bright-fox-17` and friends.

> ## ⚠️ Not encrypted yet. Read this before using it.
>
> skulk is at milestone **M1**. Messages are **NOT end-to-end encrypted** — the relay
> receives and stores your message text and can read every word of it. The room password
> also reaches the relay, which hashes it. Transport is TLS and nothing more.
>
> End-to-end encryption (OPAQUE + XChaCha20-Poly1305) lands at milestones M2–M3. Until
> then: **do not use skulk for anything you would mind a stranger reading.** It is
> experimental, unaudited, and its own specification forbids describing it as private
> until this notice can be deleted honestly.
>
> There is also **no rate limiting**, by design, so an internet-facing relay is open to
> password guessing and floods. [**SECURITY.md**](SECURITY.md) is the threat model in full:
> what is true today, what the relay is trusted for, and what only becomes true later.

---

## Quick start

Two terminals for the humans, one for the relay. You need [Elixir](https://elixir-lang.org)
1.18+ and [Go](https://go.dev) 1.26+.

### 1. Run a relay

```console
$ cd skulkd
$ mix deps.get
$ mix run --no-halt
18:08:23.568 [info] Running Skulkd.Router with Bandit at 0.0.0.0:4000 (http)
```

Check it:

```console
$ curl http://localhost:4000/healthz
{"protocol_version":0,"status":"ok"}
```

Or from the published image, if you would rather not install Elixir at all:

```console
$ docker run --rm -p 4000:4000 ghcr.io/roeeyn/skulkd:latest
```

Either way this relay is local. Running one **that other people can reach** means TLS in
front of it and a few decisions you should make deliberately —
[**docs/self-hosting.md**](docs/self-hosting.md) covers those, including what a `wss://`
deployment looks like and what it does not protect you from.

### 2. Build the client

```console
$ go build -o bin/skulk ./cmd/skulk
```

### 3. Create a room

```console
$ ./bin/skulk create --server ws://localhost:4000/v1/ws
```

skulk offers a generated passphrase and **Enter accepts it** — that is the strong path, and
it is the lazy one on purpose. Type your own only if you mean to. You will see your room id
and password; share both with the other person through a channel you trust.

### 4. Join from the second terminal

```console
$ ./bin/skulk join amber-river-copper-moon-forest-glass-harbor-star \
    --server ws://localhost:4000/v1/ws
```

skulk takes over the terminal while it runs and gives it back on exit, the way `vim` does.
Type to chat. `/help` lists the commands, `/who` shows who is here, `/room` shows the room
id again when you need to invite someone, and `/quit` leaves — as does Ctrl+C. PgUp and
PgDn — or the mouse wheel — scroll back through the transcript, and a message that arrives
while you are reading waits at the bottom instead of yanking you down to it.

skulk captures the mouse so the wheel works, which means selecting text needs **shift-drag**
(option-drag on macOS). Names are coloured per person and your own is bold; `--no-color`
turns all of it off, and so does setting `NO_COLOR`.

Your name is assigned by the relay for the length of the connection — you get a new one
each time you join. It is never one that already appears in the room's transcript, so a
message from someone who has left cannot end up looking like it came from whoever is here
now. Once their messages age out of the room's history, the name is free again.

The password is shown once, on the same screen as the room id, and never again — `/room`
deliberately does not repeat it. It does copy the room id to your clipboard, which is how
you get it out of a full-screen app that has taken the mouse.

Times are shown in your local timezone; the wire format is UTC. Messages that were already
in the room when you arrived are dimmed and marked off with a divider, so you can tell what
was said before you got there.

> `ws://` is accepted here only because `localhost` is a loopback address. A remote relay
> must be `wss://`, or skulk refuses to send your password over it.

`--debug` writes protocol diagnostics — frame types, sizes, connection states, never message
text or secrets — to stderr. The TUI owns the whole terminal, so redirect them:

```console
$ ./bin/skulk create --server ws://localhost:4000/v1/ws --debug 2>skulk.log
```

## Relay limits

The relay is bounded, not rate limited. It will not throttle a busy room, but it will
refuse to hold an unbounded number of rooms, participants, or messages — these are the
defaults from the specification's §8, and every one of them is configurable:

```bash
SKULKD_BIND=0.0.0.0:4000                  # 127.0.0.1:4000 to sit behind a TLS proxy
SKULKD_ROOM_TTL_MS=432000000              # 120h — idle rooms are deleted, not archived
SKULKD_MAX_ROOMS=10000
SKULKD_MAX_MEMBERS_PER_ROOM=32            # the 33rd joiner gets `room_full`
SKULKD_MAX_HISTORY_MESSAGES=1000          # per room
SKULKD_MAX_HISTORY_BYTES=4194304          # 4 MiB, per room
SKULKD_MAX_TOTAL_HISTORY_BYTES=536870912  # 512 MiB, across every room
SKULKD_MAX_MEMBER_BACKLOG=500             # frames one client may fall behind
```

[`skulkd/skulkd.env.example`](skulkd/skulkd.env.example) is that list with a paragraph
above each one explaining what happens when you change it — copy that file rather than
this block. A value that will not parse **stops the boot**, naming the variable: a relay
that starts having silently ignored a bound is worse than one that refuses to start.

The two per-room bounds are enforced by **evicting the oldest messages**, not by refusing
new ones — a busy room keeps working, it just stops remembering the beginning. Someone who
joins later sees whatever is still retained, so their transcript starts partway in. The
global bound is the one that refuses.

A client that stops keeping up is **disconnected abruptly** — no error frame, no close
code. Nothing the relay could send it would arrive: the queue of frames it has not read is
the problem, and anything else would go to the back of that same queue. This bound is
**best-effort**, and it is worth saying so plainly: the relay can see how many frames are
waiting to be written to a connection, but not the ones already handed to the operating
system. It cuts off runaway growth; it is not an exact ceiling on memory.

Past a limit the relay answers `server_capacity`, which says nothing about *which* limit
was reached — the numbers are not something an unauthenticated caller gets to map out.
Expired rooms are purged before anything is refused, and a live room is never deleted to
make space for a new one: running out of capacity never costs someone else their
conversation.

## For scripts and AI agents

`skulk --headless` speaks newline-delimited JSON on stdin and stdout instead of drawing a
UI. It is a **versioned contract, not a test seam**: breaking changes to it are breaking
releases.

```console
$ echo '{"id":"c1","command":"create","params":{}}' \
    | ./bin/skulk --headless --server ws://localhost:4000/v1/ws
{"event":"ready","headless_version":1,"protocol_version":0,"client_version":"0.0.0-dev"}
{"event":"connected","data":{"server":"ws://localhost:4000/v1/ws"}}
{"id":"c1","event":"created","data":{"room_id":"dress-timber-stable-ride-board-chef-student-thank","password":"viselike-budget-liability-hash-extradite-verify","username":"quiet-otter-42",…}}
```

The generated passphrase comes back **in the response**, which is what makes unattended
`create` usable — a passphrase only a human could read would be one no program could share.

Two rules worth knowing before you write an agent:

- **Passwords arrive only as JSON on stdin.** Never argv, never environment variables.
  `--password` is refused outright; process listings and shell history are not places for
  secrets.
- **stdout is only this protocol.** Every line is a complete JSON object, so you can pipe it
  straight into a parser. Diagnostics go to stderr.

The full contract, with every command, event, exit code, and a two-agent transcript, is
**[`docs/headless-v1.md`](docs/headless-v1.md)**. It is versioned independently of the wire
protocol, so an agent written today keeps working through the E2EE upgrade — the client
decrypts, and the `message` event still carries plain `text`.

## Layout

| Path | What |
| --- | --- |
| `cmd/skulk/`, `internal/` | Go client: bubbletea TUI and `--headless` mode |
| `skulkd/` | Elixir relay — Bandit + WebSock, one GenServer per room, no Phoenix |
| [`docs/spec/`](docs/spec/terminal_chat_mvp_spec.md) | the specification, v1.1 — **the implementation authority** |
| [`docs/protocol-v0.md`](docs/protocol-v0.md) | the M0 wire protocol: frames, limits, validation order |
| [`docs/headless-v1.md`](docs/headless-v1.md) | the machine interface |
| [`docs/protocol/corpus/`](docs/protocol/corpus/) | golden frame vectors — the cross-language contract |
| [`docs/self-hosting.md`](docs/self-hosting.md) | running a relay: local, Docker, and behind TLS |
| [`docs/deviations.md`](docs/deviations.md) | every deliberate departure from the spec, and when it ends |
| [`docs/designs/`](docs/designs/terminal-e2ee-chat.md) | the design doc and its full review trail |
| [`SECURITY.md`](SECURITY.md) | threat model, known gaps, and how to report a vulnerability |

## Tests

```console
$ go test -race ./...          # client
$ cd skulkd && mix test        # relay
$ cd skulkd && mix test.integration   # both: ExUnit drives real client binaries
```

That last one is the milestone gate. It boots the relay in-process, spawns real
`skulk --headless` processes, and makes them hold a conversation — which is also, by
construction, the first agent-to-agent conversation skulk supports.

The relay and the client have **independent protocol implementations in different
languages**, so a golden frame corpus keeps them honest: both walk
`docs/protocol/corpus/` and must accept and reject all 66 vectors identically, with
identical error codes, or CI fails.

## Status

M0 walking skeleton → M1 hardening → **M1.5 dogfood distribution** → M2 OPAQUE auth →
M3 E2EE → M4 integrity → M5 distribution.

M1.5 is not in the specification's ladder. It takes M5's mechanics — an image, installable
binaries, a documented deployment — and leaves §23's acceptance gate attached to the real
M5, because three of its items are impossible before end-to-end encryption exists. The
argument is [entry #1 in `docs/deviations.md`](docs/deviations.md).

**M0 and M1 are complete.** M1 added §8's capacity bounds, history eviction, backpressure,
A12's username no-recycle, and the property and differential testing of frame decoding that
[SECURITY.md](SECURITY.md) describes.

The honesty notice at the top of this file is deleted when M3 ships and not one milestone
sooner.

## License

MIT. See [LICENSE](LICENSE).
