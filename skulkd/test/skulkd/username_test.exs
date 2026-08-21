defmodule Skulkd.UsernameTest do
  @moduledoc """
  `Skulkd.Username` on its own terms.

  The generator had no tests of its own — the room suite asserted the *format* of
  what came out of it and nothing else, so the bounded-retry contract that keeps a
  `GenServer` from hanging was carried entirely by a comment. ROJ-43's acceptance
  criteria say that path "should stay tested"; it never was.

  One trap worth naming, because it is the obvious test to write and it does not
  work: **"take everything but one name, assert it returns that one" fails almost
  always.** `generate/1` draws at random a bounded number of times rather than
  enumerating, so finding a single free name in ninety thousand is a ~0.1% event.
  The tests below leave half the namespace free, which makes success a 2⁻¹⁰⁰
  proposition instead.
  """
  use ExUnit.Case, async: true

  alias Skulkd.Username

  # Spec §6.4 / protocol §4.
  @format ~r/^[a-z]+-[a-z]+-[0-9]{2}$/

  defp all_names do
    for adjective <- Username.adjectives(),
        animal <- Username.animals(),
        digits <- 0..99 do
      "#{adjective}-#{animal}-#{String.pad_leading(Integer.to_string(digits), 2, "0")}"
    end
  end

  describe "the shape of a name (spec §6.4)" do
    test "it is adjective-animal-two-digits, always two digits" do
      for _ <- 1..200 do
        assert {:ok, name} = Username.generate()
        assert name =~ @format
      end
    end

    test "single-digit suffixes are padded rather than shortened" do
      # The pad is the whole reason `00` and `07` are legal and `0` and `7` are
      # not; protocol §4's pattern requires exactly two.
      names = for _ <- 1..500, do: elem(Username.generate(), 1)
      suffixes = names |> Enum.map(&String.slice(&1, -2, 2)) |> Enum.uniq()

      assert Enum.any?(suffixes, &String.starts_with?(&1, "0"))
      assert Enum.all?(names, &(String.length(String.slice(&1, -2, 2)) == 2))
    end
  end

  describe "avoiding what is taken" do
    test "a name already taken is never returned" do
      # Half the namespace is unavailable and the generator still has to find one
      # of the other half within its retry budget.
      taken = all_names() |> Enum.take_every(2) |> MapSet.new()

      for _ <- 1..100 do
        assert {:ok, name} = Username.generate(taken)
        refute MapSet.member?(taken, name)
      end
    end

    test "it accepts any enumerable, not only a list" do
      taken = MapSet.new(["quiet-otter-42"])
      assert {:ok, name} = Username.generate(taken)
      assert name != "quiet-otter-42"
    end
  end

  describe "exhaustion fails cleanly rather than hanging" do
    test "a fully taken namespace is an error, not a livelock" do
      # The retry loop is bounded on purpose: an exhausted namespace has to surface
      # as a value the room can reply with, because the alternative is a room
      # process that never answers the join it is in the middle of.
      assert {:error, :no_username_available} = Username.generate(all_names())
    end

    test "the namespace is big enough for the bound to be theoretical" do
      # 30 adjectives x 30 animals x 100 suffixes. §8 caps a room at 32
      # participants and 1,000 retained messages, so at most ~1,032 of these can
      # ever be unavailable at once — which is what makes 100 random draws plenty.
      assert Username.namespace() == 90_000
      assert Username.namespace() == length(all_names())
    end
  end
end
