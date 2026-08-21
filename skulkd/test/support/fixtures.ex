defmodule Skulkd.Fixtures do
  @moduledoc "Test fixtures for room tests."

  @doc """
  A unique, protocol-conforming room id.

  Decision D4 in docs/protocol-v0.md validates room ids as exactly eight lowercase
  ASCII words, so tests cannot use `"test-room"`. Uniqueness has to come from the
  words themselves — the registry is global and the suite is async — so the last word
  encodes a unique integer in base 26 as letters.
  """
  def room_id do
    "amber-river-copper-moon-forest-glass-harbor-" <> unique_word()
  end

  defp unique_word do
    System.unique_integer([:positive])
    |> Integer.digits(26)
    |> Enum.map(&(&1 + ?a))
    |> List.to_string()
  end

  @doc "A password comfortably inside the 12..256 byte bounds."
  def password, do: "correct-horse-battery-staple"

  @doc "A v4 UUID, the only spelling protocol §4 accepts for `message_id`."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
  end
end

defmodule Skulkd.MemberStub do
  @moduledoc """
  Stands in for a `Skulkd.Conn` process.

  Rooms push `{:push, frame}` to member pids; this forwards each one to the test
  process as `{:pushed, member_pid, frame}` so a test can assert on what a *specific*
  member saw. Started unlinked so a test can kill it (`Process.exit(pid, :kill)`)
  to exercise the `:DOWN` path without taking the test down with it.
  """

  def start(owner \\ self()) do
    spawn(fn -> loop(owner) end)
  end

  defp loop(owner) do
    receive do
      {:push, frame} ->
        send(owner, {:pushed, self(), frame})
        loop(owner)

      :stop ->
        :ok
    end
  end

  @doc "Asserts nothing was pushed to anyone within `timeout`."
  defmacro refute_pushed(timeout \\ 50) do
    quote do
      refute_receive {:pushed, _, _}, unquote(timeout)
    end
  end
end
