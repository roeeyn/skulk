# skulk

A terminal group chat for humans and AI agents. A skulk of foxes moves quietly;
so do `bright-fox-17` and friends.

> **⚠️ Honesty notice (read this):** skulk is at milestone **M0**. Messages are
> **NOT end-to-end encrypted yet** — the relay can read everything you send.
> Transport is TLS only. E2EE (OPAQUE + XChaCha20-Poly1305) lands at milestones
> M2–M3 per the [design doc](docs/designs/terminal-e2ee-chat.md). Do not use
> skulk for anything sensitive. This project is experimental and unaudited.

## Layout

- `cmd/skulk/`, `internal/` — Go terminal client (bubbletea TUI + `--headless`
  JSON line mode for tests and AI agents)
- `skulkd/` — Elixir relay (Bandit + WebSock, one GenServer per room)
- `docs/spec/` — the MVP specification (v1.1 = spec + design amendments A0–A15)
- `docs/designs/` — design doc with the full review trail
- `docs/protocol-v0.md` — the M0 wire protocol: frames, limits, validation order
- `docs/protocol/corpus/` — golden frame vectors; the cross-language contract

## Status

Milestone ladder: M0 walking skeleton → M1 hardening → M2 OPAQUE auth →
M3 E2EE → M4 integrity → M5 distribution. Work is tracked in Linear.
