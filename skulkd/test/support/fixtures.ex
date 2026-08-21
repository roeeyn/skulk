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

  @doc """
  Wedges the stub's mailbox with `count` messages it will never take out.

  The loop below is a *selective* receive: it matches `{:push, _}`, `:drain` and
  `:stop`, and nothing else. So `:junk` accumulates and counts toward
  `message_queue_len` while real pushes keep draining — which is what makes the
  ROJ-42 backpressure boundary testable to the exact message, with no frame
  counting and no sleeping.
  """
  def wedge(pid, count) do
    for _ <- 1..count, do: send(pid, :junk)
    :ok
  end

  @doc """
  A member that reads its mailbox and throws everything away.

  For tests that flood a room and care about the room's state rather than about
  what arrived. The default member is the test process itself, which forwards
  nothing and drains nothing — past ROJ-42's backlog bound the relay quite
  correctly disconnects it, which is a true result and a useless test.
  """
  def sink do
    spawn(fn -> sink_loop() end)
  end

  defp sink_loop do
    receive do
      _anything -> sink_loop()
    end
  end

  @doc "Flushes the wedged junk, putting the stub back under any backlog bound."
  def drain(pid), do: send(pid, :drain)

  @doc """
  Blocks until the stub has processed everything already in its mailbox.

  Without this, a test racing the room's own pushes would be measuring a mailbox
  that is still settling.
  """
  def settle(pid) do
    send(pid, {:push, :settle})

    receive do
      {:pushed, ^pid, :settle} -> :ok
    after
      1_000 -> raise "stub never settled"
    end
  end

  defp loop(owner) do
    receive do
      {:push, frame} ->
        send(owner, {:pushed, self(), frame})
        loop(owner)

      :drain ->
        flush_junk()
        loop(owner)

      :stop ->
        :ok
    end
  end

  defp flush_junk do
    receive do
      :junk -> flush_junk()
    after
      0 -> :ok
    end
  end

  @doc "Asserts nothing was pushed to anyone within `timeout`."
  defmacro refute_pushed(timeout \\ 50) do
    quote do
      refute_receive {:pushed, _, _}, unquote(timeout)
    end
  end
end
