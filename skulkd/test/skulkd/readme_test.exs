defmodule Skulkd.ReadmeTest do
  @moduledoc """
  §27's honesty notice, which the README is required to carry and nothing was
  checking.

  > "**Until end-to-end encryption actually ships, say so.** The README must
  > state, above the fold, that the relay can read every message. **This survives
  > every README edit** until the milestone that makes it false."

  `Skulkd.SecurityDocTest` has guarded the same claim in SECURITY.md since ROJ-45.
  The README never had that protection, which went unnoticed until the file was
  restructured wholesale — the exact event the spec's "survives every README edit"
  clause is written for, and the exact event during which a notice quietly gets
  shorter.

  "Above the fold" is enforced as: before the first instruction telling anyone to
  install or run anything. A warning underneath the quick start is a warning read
  after the decision it was meant to inform.
  """
  use ExUnit.Case, async: true

  @readme Path.expand("../../../README.md", __DIR__)
  @external_resource @readme

  defp readme, do: File.read!(@readme)

  test "the notice appears before anything tells the reader to install or run" do
    readme = readme()

    notice =
      :binary.match(readme, "NOT end-to-end encrypted")
      |> case do
        {at, _} -> at
        :nomatch -> flunk("the README does not say messages are NOT end-to-end encrypted")
      end

    instruction =
      Regex.run(~r/^#+ .*(install|quick start)/im, readme, return: :index)
      |> case do
        [{at, _} | _] -> at
        nil -> flunk("the README has no install or quick-start heading — did it move?")
      end

    assert notice < instruction, """
    The honesty notice appears AFTER the first install/quick-start heading.

    §27 requires it above the fold. A reader who has already run the install
    command has made the decision the notice exists to inform.
    """
  end

  test "it says what the relay can do, not what it might be able to do" do
    readme = readme()

    assert readme =~ ~r/can read every word/i,
           "§27: the README must state that the relay can read every message"

    assert readme =~ ~r/no rate limiting/i,
           "§19's consequence belongs here too — an internet-facing relay has no abuse controls"

    # Hedging is the specific failure mode, and the one a rewrite introduces
    # without meaning to. "May be able to read" is a sentence about a
    # possibility; the relay receives plaintext and stores it.
    for hedge <- [
          ~r/\bmay be able to read\b/i,
          ~r/\bcould potentially read\b/i,
          ~r/\bmight be able to read\b/i
        ] do
      refute readme =~ hedge,
             "the relay does not merely have the ability to read messages — it receives plaintext"
    end
  end

  test "it is not described as beta, stable, or production-ready" do
    # M1.5 made skulk installable by strangers, which is precisely when the
    # temptation to reach for a friendlier word arrives. §19 requires
    # "experimental and not production-ready"; §23 requires "experimental,
    # unaudited, and unsuitable for high-risk use".
    readme = readme()

    assert readme =~ ~r/experimental/i

    for softening <- [~r/\bbeta\b/i, ~r/\bproduction[- ]ready\b/i, ~r/\bbattle[- ]tested\b/i] do
      refute readme =~ softening,
             """
             "beta" and its neighbours imply feature-complete and stabilising, which is \
             false while the relay reads every message. The spec asks for "experimental".
             """
    end
  end
end
