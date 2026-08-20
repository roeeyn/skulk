# Integration suite

ExUnit drives everything (design A14): this suite boots `skulkd` in-process and drives
real `skulk --headless` binaries through Elixir Ports, so it is the compatibility suite
for `docs/headless-v1.md` as well as the M0 milestone gate.

**Owner: ROJ-35 (M0-7).** The directory exists ahead of it so CI has a stable place to
point at and so `mix test.integration` is a real command from day one rather than a
promise. It runs zero tests until ROJ-35 lands, and exits 0 while doing so.

## Running it

```console
mix test.integration          # this directory only
```

Tests here MUST carry `@moduletag :integration`. `test/test_helper.exs` excludes that tag
by default, so the fast `mix test` loop stays fast; `mix test.integration` re-includes it.

## The client binary

CI's integration job builds the Go client to `bin/skulk` at the repository root and exports
`SKULK_BIN` to point at it. ROJ-35's harness should read `SKULK_BIN` and fall back to
building on demand, so the suite runs locally without a CI-shaped environment.
