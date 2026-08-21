# Deviations from the specification

Spec §27: *"Record every unavoidable deviation from this specification in
`docs/deviations.md` before implementing it."*

This file is that record. It exists so that a reader who finds the code doing something
[the specification](spec/terminal_chat_mvp_spec.md) does not describe can find out whether
that was a decision or a mistake — and, if it was a decision, what it cost and when it
ends.

Two rules about the entries below:

- **Before, not after.** An entry written after the code is a changelog. §27 asks for the
  argument to be made while it can still change the answer.
- **Each one names its end.** A deviation with no expiry is a fork of the specification.

---

## 1. Distribution work pulled ahead of M2 and M3

**Recorded** 2026-08-21, before the first M1.5 commit.
**Deviates from** §25 (the milestone ladder), which places distribution at **M5**.
**Ends** when M5 ships and closes the §23 gate for real.

### What the specification says

§25's ladder puts release binaries, install one-liners and the relay image at **M5**, after
M2 (OPAQUE), M3 (end-to-end encryption) and M4 (integrity). §23's acceptance checklist is
declared to be "the M5 gate, not the M0 gate".

### What we are doing instead

Shipping M5's *mechanics* now, as a milestone called **M1.5**: a public repository, a
Homebrew tap for the client, a published relay image, and a documented path to reach a
relay from another machine. The protocol stays `v0`. Nothing about the security posture
changes.

### Why it is unavoidable rather than merely convenient

skulk needs real use before the cryptography lands, and today real use costs a git clone,
two toolchains and a `mix run`. That is the convenience argument, and on its own it would
not justify an entry here.

The argument that does: **M2 and M3 are protocol version bumps** (`v0 → v2 → v3`), and a
protocol bump requires client and relay to move in lockstep — the relay answers a stale
client with `unsupported_protocol_version` and closes the connection. Every dogfooder
breaks on the day M2 ships. `brew upgrade` and `docker pull` are what make that a Tuesday
rather than a support incident. Distribution is not a detour from the crypto work; it is
the delivery mechanism for it.

### What this does **not** do: claim §23

At least three §23 acceptance items are impossible before M3 exists:

- *"A joining client receives all retained **encrypted** history."*
- *"A packet/frame capture at the relay contains **no plaintext message**, plaintext
  password, or room key."*
- *"The relay source contains **no path that receives or logs plaintext messages**."*

Calling this M5 would mean either failing that gate or quietly weakening it. So M1.5 takes
the mechanics and leaves §23 attached to the real M5, exactly as M0.5 did before it.

**Windows stays out of scope.** §23 requires Linux, macOS and Windows builds at M5; the
dogfood subset needs macOS and Linux. Windows returns with the gate it belongs to.

### The two things that get more dangerous, stated rather than assumed

**Rate limiting is still deferred.** §26 lists application-level rate limiting and abuse
controls as considerable "only after MVP completion", and §19 states the consequence: an
internet-facing relay without it is open to password guessing, room floods, connection
floods and denial of service. Making the relay easy to reach does not change that; it
raises the odds of someone reaching it. A publicly reachable relay cannot be given abuse
controls without a second deviation. The mitigations that remain are behavioural — accept
the generated passphrase (~77 bits, which puts grinding out of reach) and do not post room
ids anywhere public — and they belong in the dogfood documentation, not in a reader's
assumptions.

**The honesty notice does not move.** §27 requires the README to state above the fold that
the relay can read every message, "until end-to-end encryption actually ships". Wider
distribution is the strongest possible reason to keep that sentence and the weakest
possible reason to soften it. **"Beta" is the wrong word** — it implies feature-complete
and stabilising. §19 says *experimental and not production-ready*; §23 says *experimental,
unaudited, and unsuitable for high-risk use*. `Skulkd.SecurityDocTest` already fails if the
un-hedged version of that claim is edited into something more comfortable.

---

## 2. The relay is configured by environment variable, not by the flags in §7.4

**Recorded** 2026-08-21, before `config/runtime.exs` existed.
**Deviates from** §7.4, which spells relay configuration as command-line flags.
**Ends** at M5, when `skulkd` ships as a binary with its own argument parsing.

### What the specification says

§7.4 gives the relay a flag interface: `--bind`, `--room-ttl`, `--max-rooms`,
`--max-members-per-room`, `--max-history-messages`, `--max-history-bytes`,
`--max-total-history-bytes`.

### What we are doing instead

Every one of those bounds is read from an environment variable —
`SKULKD_MAX_ROOMS` and friends — parsed once at boot by `Skulkd.Config` and written into
application environment. `Skulkd.Limits` reads it from there, unchanged.

### Why

The deliverable this milestone owes (§24) is a **`Dockerfile` and minimal container
configuration**, and a container is configured by its environment. Passing flags to an
Elixir release means wrapping its entrypoint, which puts the relay's interface inside a
shell script — a worse place for it than the specification's own §24 bullet, which asks
for an "example environment/configuration file containing no secrets" and so already
anticipates environment variables.

The flag names survive as the variable names (`--max-rooms` → `SKULKD_MAX_ROOMS`), so the
two spellings stay one interface with two syntaxes rather than two interfaces. Two of them
do not survive intact, and both are named here rather than left to be discovered:

- **`--room-ttl <DURATION>` becomes `SKULKD_ROOM_TTL_MS`.** A duration syntax is a small
  language with its own bugs — `120h`, `5m`, `1h30m`, and the argument about what `1M`
  means — for a value that is set once per deployment. Milliseconds, with the arithmetic
  spelled out in a comment in the example file.
- **`--max-message-bytes` has no variable at all.** That bound is `4096`, and it lives in
  `Skulkd.Protocol` as a compile-time constant because it is half of a cross-language
  contract: the Go client carries the same number and `docs/protocol/corpus/` fails CI if
  the two disagree. Making it configurable on the relay alone would let a deployment drift
  out of the corpus that proves the two implementations agree. It becomes configurable
  when both sides can negotiate it, which is not this milestone.

### What it costs

A deployment written against §7.4's flags does not work today. The mapping is mechanical
and documented in [`docs/self-hosting.md`](self-hosting.md) and
[`skulkd/skulkd.env.example`](../skulkd/skulkd.env.example), and a test fails if a bound
gains a key without gaining an environment variable — but a reader of §7.4 alone will
reach for the wrong thing, which is precisely why this entry exists.
