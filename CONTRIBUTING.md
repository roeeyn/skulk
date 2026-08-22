# Contributing to skulk

skulk is two programs that have to agree with each other: a Go client (`cmd/skulk`,
`internal/`) and an Elixir relay (`skulkd/`). They implement the wire protocol
**independently**, which is a deliberate design choice — and the reason a good deal of the
test suite exists to catch them disagreeing.

## Setting up

| | |
| --- | --- |
| [Elixir](https://elixir-lang.org) 1.18+ on OTP 27 | the relay |
| [Go](https://go.dev) 1.26.6+ | the client |
| [go-task](https://taskfile.dev/installation) | optional, but every command below has a shortcut |
| Docker | optional — only to build the relay image |

```console
$ git clone https://github.com/roeeyn/skulk.git && cd skulk
$ task deps          # or: cd skulkd && mix deps.get
```

`task` with no arguments lists everything. It works from any directory in the repo.

## Running it locally

Two terminals:

```console
$ task relay                     # the relay, on :4000
$ task create                    # builds the client, creates a room, joins it
$ task join -- <room-id>         # a second person
```

`task relay PORT=4001` and `task create PORT=4001` agree with each other, which is how you
run two relays at once.

Building the client by hand:

```console
$ task build                     # → bin/skulk, stamped with `git describe`
$ go build -o bin/skulk ./cmd/skulk
```

`task build` injects the version, so `skulk --version` reports the commit you are on rather
than `0.0.0-dev`. Plain `go build` does not.

## Tests

```console
$ task test                      # everything
$ task test:client               # Go, with -race
$ task test:relay                # Elixir
$ task test:integration          # both at once
```

**The integration suite is the milestone gate.** It boots the relay in-process, spawns real
`skulk --headless` binaries, and makes them hold a conversation — which is also, by
construction, the first agent-to-agent conversation skulk supports. If you change anything
either side of the wire, this is the suite that notices.

**The golden corpus is the cross-language contract.** Both implementations walk
[`docs/protocol/corpus/`](docs/protocol/corpus/) and must accept and reject all 66 vectors
identically, with identical error codes, or CI fails. A differential fuzzing harness
generates frames nobody wrote and compares the two verdicts; it has found four real
divergences, each now frozen as a corpus vector.

`-race` is not optional on the client. The detector has found real bugs here that the plain
run did not.

## Before you push

```console
$ task ci                        # lint + test + audit, in CI's order
```

Separately if you prefer:

```console
$ task fmt                       # gofmt + mix format
$ task lint                      # format checks, go vet, build
$ task audit                     # govulncheck, go-licenses, mix deps.audit, mix licenses.check
$ task image                     # build the relay image and check it boots
```

`task audit` is §22.3's dependency vulnerability and license checks. All four fail rather
than warn — a check that can only warn is not a check. If one goes red without you having
touched a dependency, a database moved, and the fix is usually a version bump.

## How this repository works

**The specification is the authority.** [`docs/spec/`](docs/spec/terminal_chat_mvp_spec.md)
decides what skulk is; the code follows it. When they disagree, the code is wrong.

**Deviations get written down first.** If something genuinely cannot follow the spec, it
goes in [`docs/deviations.md`](docs/deviations.md) — with the reason, and with the milestone
at which it ends — *before* the code lands. A deviation with no expiry is a fork of the
specification.

**Tests come from acceptance criteria, and then get attacked.** The house practice is
spec → failing test → implementation → **mutation pass**: revert the implementation and
confirm the test actually goes red. A mutation that survives means the test was vacuous.
That pass has caught vacuous tests in this repository more than once.

**Some rules are not style preferences.** They are in the spec's §27 and they have tests
behind them:

- Passwords never appear in argv, and never in logs — including in tests.
- `--debug` output never contains message text or secret material.
- Nothing describes transport encryption as end-to-end encryption.
- The README's honesty notice survives every edit until M3 actually ships.

## Layout

| Path | What |
| --- | --- |
| `cmd/skulk/`, `internal/` | Go client: bubbletea TUI and `--headless` mode |
| `cmd/protocol-oracle/` | the Go validator as a filter, so ExUnit can fuzz both codecs at once |
| `skulkd/` | Elixir relay — Bandit + WebSock, one GenServer per room, no Phoenix |
| `skulkd/test/integration/` | the milestone gate: ExUnit driving real client binaries |
| [`docs/spec/`](docs/spec/terminal_chat_mvp_spec.md) | the specification — the implementation authority |
| [`docs/protocol-v0.md`](docs/protocol-v0.md) | the wire protocol: frames, limits, validation order |
| [`docs/protocol/corpus/`](docs/protocol/corpus/) | golden frame vectors — the cross-language contract |
| [`docs/headless-v1.md`](docs/headless-v1.md) | the machine interface |
| [`docs/designs/`](docs/designs/terminal-e2ee-chat.md) | the design document and its full review trail |
| [`docs/deviations.md`](docs/deviations.md) | every deliberate departure from the spec |
| `Dockerfile`, `.goreleaser.yaml` | how the relay image and the client binaries are built |

## Releases

A tag beginning `v` publishes **both halves from the same commit**: the client (macOS
binaries, a GitHub release, the Homebrew cask) and the relay image at
`ghcr.io/roeeyn/skulkd`.

That pairing is not tidiness. M2 and M3 bump the protocol version, and a stale client
against a new relay is refused with `unsupported_protocol_version` — the protocol working
correctly, looking exactly like the application being broken. One tag for both is what makes
"we are both on 0.4.0" a diagnosis somebody can actually perform.

`latest` follows stable releases only: a tag with a hyphen in it (`v0.2.0-rc1`) publishes
under its own version and leaves `latest` alone. Rehearse with **Actions → Release → Run
workflow**, which builds everything and publishes only a throwaway `0.0.0-dryrun` image.

## Reporting a vulnerability

Not here. Use GitHub's private advisory form — *Security* → *Report a vulnerability* — as
described in [SECURITY.md](SECURITY.md).
