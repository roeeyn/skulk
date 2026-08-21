defmodule Skulkd.SecurityDocTest do
  @moduledoc """
  `SECURITY.md` states a pinned cryptographic dependency version. This checks it is
  the version actually locked.

  Spec §24 requires that file to name "pinned crypto dependencies and versions", and
  a pinned-version claim that has quietly gone stale is precisely the lie the
  requirement exists to prevent — the reader has no way to tell a current number
  from one that was true eight months ago.

  Prose counts in this repository have needed correcting by hand five times in one
  milestone (the corpus vector total, as it grew from 59 to 66). The response
  elsewhere was to state a number in one place and link to it. That is not
  available for a lockfile version, so it gets a test instead.
  """
  use ExUnit.Case, async: true

  @security_md Path.expand("../../../SECURITY.md", __DIR__)
  @mix_lock Path.expand("../../mix.lock", __DIR__)

  @external_resource @security_md
  @external_resource @mix_lock

  # Everything SECURITY.md's dependency table claims a version for. Adding a
  # cryptographic dependency means adding it here and to that table, and this test
  # is what makes forgetting noisy.
  @claimed ~w(argon2_elixir comeonin)

  defp documented_version(dependency) do
    @security_md
    |> File.read!()
    |> then(&Regex.run(~r/`?#{dependency}`?[^|\n]*\|\s*`([^`]+)`/, &1))
    |> case do
      [_, version] -> version
      nil -> flunk("SECURITY.md's dependency table does not mention #{dependency}")
    end
  end

  defp locked_version(dependency) do
    @mix_lock
    |> File.read!()
    |> then(&Regex.run(~r/"#{dependency}": \{:hex, :#{dependency}, "([^"]+)"/, &1))
    |> case do
      [_, version] -> version
      nil -> flunk("#{dependency} is not in mix.lock")
    end
  end

  test "SECURITY.md pins the versions that are actually locked" do
    for dependency <- @claimed do
      assert documented_version(dependency) == locked_version(dependency),
             """
             SECURITY.md says #{dependency} is pinned at #{documented_version(dependency)}, \
             but mix.lock has #{locked_version(dependency)}.

             Spec §24 requires SECURITY.md to name pinned crypto dependencies and their
             versions. Update the table there — a stale version in a security document is
             worse than no version, because a reader cannot tell it is stale.
             """
    end
  end

  test "the honesty notice has not been quietly softened" do
    # §27 and the ticket's own acceptance criteria: the relay reads every message,
    # stated with no hedging, until end-to-end encryption actually ships. This is
    # the sentence most likely to get edited into something more comfortable.
    security = File.read!(@security_md)

    assert security =~ ~r/not end-to-end encrypted/i
    assert security =~ ~r/relay reads everything/i

    # Hedging is the specific failure mode. "The relay may be able to read your
    # messages" is a sentence about a possibility; the relay receives plaintext and
    # stores it, which is a sentence about a fact.
    for hedge <- [~r/\bmay be able to read\b/i, ~r/\bcould potentially read\b/i] do
      refute security =~ hedge,
             "the relay does not merely have the ability to read messages — it receives plaintext"
    end
  end
end
