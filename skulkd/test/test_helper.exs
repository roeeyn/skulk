# Integration tests (test/integration, owned by ROJ-35) are excluded from the fast
# `mix test` loop: they boot the relay and drive real Go client binaries through
# Ports. `mix test.integration` re-includes them.
ExUnit.start(exclude: [:integration])
