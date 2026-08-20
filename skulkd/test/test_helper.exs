# Integration tests (test/integration, owned by ROJ-35) are excluded from the fast
# `mix test` loop: they boot the relay and drive real Go client binaries through
# Ports. `mix test.integration` re-includes them.
# capture_log keeps room lifecycle logs out of the test output while leaving the
# :info level intact — the AC9 test asserts on what IS logged, so lowering the
# level to silence the noise would make that assertion vacuous.
ExUnit.start(exclude: [:integration], capture_log: true)
