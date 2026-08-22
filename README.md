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

## Install

Two pieces: the **client** you type into, and the **relay** they connect through.

```console
$ brew install --cask roeeyn/tools/skulk     # the client
$ docker pull ghcr.io/roeeyn/skulkd:latest   # the relay
```

The client is macOS only for now (Apple Silicon and Intel); the relay image is
`linux/arm64`. Anywhere else, build from source — see
[CONTRIBUTING.md](CONTRIBUTING.md).

<details>
<summary>The binaries are unsigned</summary>

The cask clears Gatekeeper's quarantine flag on install, which is goreleaser's documented
answer for an unsigned cask and is worth knowing you are accepting. Proper signing needs an
Apple Developer account — a decision for whenever skulk stops being an experiment.

</details>

## Quick start

Three terminals: one for the relay, two for the people.

### 1. Start a relay

```console
$ docker run --rm -p 4000:4000 ghcr.io/roeeyn/skulkd:latest
```

Point the client at it once, and every command below is shorter:

```console
$ export SKULK_SERVER=ws://localhost:4000/v1/ws
```

> There is **no default relay** — `--server` or `SKULK_SERVER` is always required. And
> `ws://` is only accepted here because `localhost` is a loopback address: a remote relay
> must be `wss://`, or skulk refuses to send your password over it.

### 2. Create a room

```console
$ skulk create
```

skulk offers a generated passphrase and **Enter accepts it** — that is the strong path, and
it is the lazy one on purpose. Type your own only if you mean to.

You get a room id and a password. Share **both**, through a channel you trust.

### 3. Join from the other terminal

```console
$ skulk join amber-river-copper-moon-forest-glass-harbor-star
```

That is it. Type to chat.

## In the room

skulk takes over the terminal while it runs and gives it back on exit, the way `vim` does.

| | |
| --- | --- |
| `/help` | list the commands |
| `/who` | who is here right now |
| `/room` | show the room id again, and copy it to your clipboard |
| `/quit` or `Ctrl+C` | leave |
| PgUp / PgDn, mouse wheel | scroll back; a message arriving while you read waits at the bottom |
| shift-drag (option-drag on macOS) | select text — skulk captures the mouse, so plain drag scrolls |

Three things that surprise people:

- **Your name is not yours.** The relay assigns one per connection, and you get a new one
  every time you join. It is never a name still visible in the transcript, so a departed
  person's messages cannot come to look like they were written by whoever is here now.
- **The password is shown once**, on the same screen as the room id. `/room` deliberately
  will not repeat it.
- **Earlier messages are dimmed** and marked off with a divider, so you can tell what was
  said before you arrived. Times are local; the wire format is UTC.

`--no-color` turns colour off, and so does setting `NO_COLOR`. `--debug` writes protocol
diagnostics to stderr — frame types, sizes, connection states, never message text or
secrets — and since the UI owns the terminal, redirect them:

```console
$ skulk create --debug 2>skulk.log
```

## For scripts and AI agents

`skulk --headless` speaks newline-delimited JSON on stdin and stdout instead of drawing a
UI. It is a **versioned contract, not a test seam**: breaking changes to it are breaking
releases.

```console
$ echo '{"id":"c1","command":"create","params":{}}' | skulk --headless
{"client_version":"0.1.1","event":"ready","headless_version":1,"protocol_version":0}
{"data":{"server":"ws://localhost:4000/v1/ws"},"event":"connected"}
{"id":"c1","event":"created","data":{"room_id":"diary-daring-lazy-able-demise-home-found-victory","password":"overhead-mockup-generous-crucial-vintage-gladiator","username":"wandering-gecko-46",…}}
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

## Running a relay for other people

The relay above is local. One that others can reach needs TLS in front of it and a few
decisions you should make deliberately — **[`docs/self-hosting.md`](docs/self-hosting.md)**
covers all of it, including a working `wss://` deployment and what it does *not* protect
you from.

### Relay limits

The relay is **bounded, not rate limited**. It will not throttle a busy room, but it will
refuse to hold unbounded rooms, participants, or history. Every bound is an environment
variable with a specification default:

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

Copy **[`skulkd/skulkd.env.example`](skulkd/skulkd.env.example)** rather than this block —
it explains what changing each one actually does. A value that will not parse **stops the
boot**, naming the variable: a relay that starts having silently ignored a bound is worse
than one that refuses to start.

The per-room history bounds **evict** the oldest messages, so a busy room keeps working and
just stops remembering its beginning. The global bound is the one that **refuses**, with
`server_capacity` — which never says *which* limit was hit, and never costs someone else
their conversation to make room for yours.

## Documentation

| | |
| --- | --- |
| [SECURITY.md](SECURITY.md) | the threat model: what is true today, what the relay is trusted for, what changes at M3 |
| [docs/self-hosting.md](docs/self-hosting.md) | running a relay: local, Docker, and behind TLS |
| [docs/headless-v1.md](docs/headless-v1.md) | the machine interface for scripts and agents |
| [CONTRIBUTING.md](CONTRIBUTING.md) | building it, testing it, and how this repository works |
| [docs/protocol-v0.md](docs/protocol-v0.md) | the wire protocol: frames, limits, validation order |
| [docs/spec/](docs/spec/terminal_chat_mvp_spec.md) | the specification — **the implementation authority** |
| [docs/deviations.md](docs/deviations.md) | every deliberate departure from it, and when each one ends |

## Status

**M0, M1 and M1.5 are complete.**

```
M0 skeleton → M1 hardening → M1.5 distribution → M2 OPAQUE auth → M3 E2EE → M4 integrity → M5
```

M2 and M3 are protocol version bumps, so client and relay must move together — they are
published from the same tag for exactly that reason. **The honesty notice at the top of
this file is deleted when M3 ships, and not one milestone sooner.**

## License

MIT. See [LICENSE](LICENSE).
