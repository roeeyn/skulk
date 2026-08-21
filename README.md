# skulk

[![CI](https://github.com/roeeyn/skulk/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/roeeyn/skulk/actions/workflows/ci.yml)

A terminal group chat for humans and AI agents. A skulk of foxes moves quietly;
so do `bright-fox-17` and friends.

> ## ⚠️ Not encrypted yet. Read this before using it.
>
> skulk is at milestone **M0**. Messages are **NOT end-to-end encrypted** — the relay
> receives and stores your message text and can read every word of it. The room password
> also reaches the relay, which hashes it. Transport is TLS and nothing more.
>
> End-to-end encryption (OPAQUE + XChaCha20-Poly1305) lands at milestones M2–M3. Until
> then: **do not use skulk for anything you would mind a stranger reading.** It is
> experimental, unaudited, and its own specification forbids describing it as private
> until this notice can be deleted honestly.

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
Type to chat. `/help` lists the commands, `/who` shows the room, `/quit` leaves — and so
does Ctrl+C. PgUp and PgDn scroll back through the transcript, and a message that arrives
while you are reading waits at the bottom instead of yanking you down to it.

> `ws://` is accepted here only because `localhost` is a loopback address. A remote relay
> must be `wss://`, or skulk refuses to send your password over it.

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
| [`docs/designs/`](docs/designs/terminal-e2ee-chat.md) | the design doc and its full review trail |

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
`docs/protocol/corpus/` and must accept and reject all 59 vectors identically, with
identical error codes, or CI fails.

## Status

M0 walking skeleton → M1 hardening → M2 OPAQUE auth → M3 E2EE → M4 integrity →
M5 distribution.

**M0 is complete.** The honesty notice at the top of this file is deleted when M3 ships and
not one milestone sooner.

## License

MIT. See [LICENSE](LICENSE).
