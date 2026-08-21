defmodule Skulkd.HistoryEvictionTest do
  @moduledoc """
  ROJ-41 (M1-3) acceptance criteria: spec §15's history eviction, one describe
  block per criterion.

  Rooms retained every message forever. §15 says they must not: when a room reaches
  a per-room cap it evicts the **oldest** messages, before appending the new one,
  until both the message-count and the byte-count limits are satisfied.

  **Not `async`.** A test here can push the global counter to its cap, and a chat
  refused for capacity purges expired rooms (§8) — with a fake clock wound past
  every other test's TTL. Running concurrently, this suite would reap the rooms of
  whichever async test happened to be mid-example.

  Each room gets a counter of its own, which makes `Capacity.total/1` a direct
  reading of *that room's* retained bytes — so the acceptance criterion that asks
  for the global counter to be asserted rather than the room's own bookkeeping is
  satisfied by construction rather than by a second accessor.
  """
  use ExUnit.Case, async: false

  alias Skulkd.Capacity
  alias Skulkd.Clock
  alias Skulkd.Fixtures
  alias Skulkd.Frames
  alias Skulkd.MemberStub
  alias Skulkd.Protocol
  alias Skulkd.Room
  alias Skulkd.Rooms

  @ttl :timer.hours(120)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp capacity(limit) do
    name = :"eviction_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Capacity, name: name, limit: limit}, id: name))
    name
  end

  defp fake_time do
    {:ok, clock} = Clock.Fake.start_link()
    {clock, [clock: Clock.Fake.fun(clock), timer: Skulkd.Timer.Manual, ttl_ms: @ttl]}
  end

  defp create(opts \\ []) do
    room_id = Fixtures.room_id()
    {:ok, session} = Rooms.create(room_id, Fixtures.password(), opts)
    {room_id, session}
  end

  defp chat(room_id, sender_id, text, opts \\ []) do
    Room.send_chat(room_id, sender_id, Fixtures.uuid(), text, opts)
  end

  defp encoded_size(payload), do: byte_size(Jason.encode!(payload))

  # A joiner's view is the only way to read retained history from outside the room,
  # which is the right way round: §15 is a statement about what a snapshot contains.
  defp snapshot(room_id) do
    {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
    joiner
  end

  defp texts(room_id), do: Enum.map(snapshot(room_id).history, & &1["text"])

  # One small message's encoded size in a room of its own. Room ids are a fixed
  # width but generated usernames are not, so this is within a few bytes of the
  # size the room under test will see — every cap derived from it below leaves at
  # least half a message of slack.
  defp sample_size do
    {room_id, session} = create(capacity: capacity(10_000_000))
    {:ok, payload} = chat(room_id, session.sender_id, "sample")
    encoded_size(payload)
  end

  defp retained_bytes(room_id) do
    room_id |> snapshot() |> Map.fetch!(:history) |> Enum.map(&encoded_size/1) |> Enum.sum()
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC1 · the message-count cap (§8, §15)" do
    test "the message past the cap evicts the oldest, and the room holds exactly N" do
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_messages: 3)

      for n <- 1..3, do: {:ok, _} = chat(room_id, creator.sender_id, "m#{n}")
      assert texts(room_id) == ~w(m1 m2 m3)

      {:ok, _} = chat(room_id, creator.sender_id, "m4")
      assert texts(room_id) == ~w(m2 m3 m4)

      {:ok, _} = chat(room_id, creator.sender_id, "m5")
      assert texts(room_id) == ~w(m3 m4 m5)
    end

    test "a room at its byte cap keeps holding as much as it is allowed to" do
      # Over-eviction satisfies both caps exactly as well as correct eviction does,
      # so a test that only checks the caps hold cannot tell the two apart. This
      # pins the other side of it: the room is still full.
      sample = sample_size()
      cap = capacity(10_000_000)

      {room_id, creator} =
        create(
          capacity: cap,
          max_history_bytes: div(7 * sample, 2),
          max_history_messages: 1_000
        )

      for n <- 1..10 do
        assert {:ok, _} = chat(room_id, creator.sender_id, "sample")
        assert length(texts(room_id)) == min(n, 3), "after #{n} messages"
      end
    end

    test "the newest message always survives its own eviction" do
      # §15 evicts BEFORE appending. At a cap of one, an implementation that
      # appended first and then trimmed to size from the wrong end would leave the
      # room holding the message it just replaced, or nothing at all.
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_messages: 1)

      for n <- 1..5 do
        {:ok, _} = chat(room_id, creator.sender_id, "m#{n}")
        assert texts(room_id) == ["m#{n}"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC2 · the byte cap (§8, §15)" do
    test "one large message costs several old ones, and the survivors fit" do
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_bytes: 4_000)

      for n <- 1..6, do: {:ok, _} = chat(room_id, creator.sender_id, "small #{n}")
      assert length(texts(room_id)) == 6

      assert {:ok, big} = chat(room_id, creator.sender_id, String.duplicate("x", 3_000))
      remaining = texts(room_id)

      # The newcomer is here, several of the old ones are not, and some survived —
      # eviction stops as soon as the message fits, rather than clearing the room.
      assert List.last(remaining) == big["text"]
      assert length(remaining) >= 2
      assert 6 - (length(remaining) - 1) >= 2

      # Only this room spends against this counter, so the counter IS the room's
      # retained bytes.
      assert Capacity.total(cap) <= 4_000
    end

    test "both caps hold together after every append" do
      cap = capacity(10_000_000)

      {room_id, creator} =
        create(capacity: cap, max_history_messages: 4, max_history_bytes: 2_000)

      for n <- 1..12 do
        text = if rem(n, 3) == 0, do: String.duplicate("y", 600), else: "short #{n}"
        assert {:ok, _} = chat(room_id, creator.sender_id, text)

        assert length(texts(room_id)) <= 4, "message-count cap exceeded after #{n}"
        assert Capacity.total(cap) <= 2_000, "byte cap exceeded after #{n}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC3 · a message bigger than the whole cap is refused, not accommodated" do
    test "message_too_large, and it evicts nothing" do
      {clock, time} = fake_time()
      cap = capacity(10_000_000)
      {room_id, creator} = create(time ++ [capacity: cap, max_history_bytes: 1_000])

      assert {:ok, first} = chat(room_id, creator.sender_id, "keep me")
      before = Capacity.total(cap)

      member = MemberStub.start()
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: member)
      deadline = joiner.expires_at

      Clock.Fake.advance(clock, :timer.hours(1))

      # §15: reject it rather than evict the entire room to fit it.
      assert {:error, :message_too_large} =
               chat(room_id, creator.sender_id, String.duplicate("x", 2_000))

      assert texts(room_id) == ["keep me"]
      assert Capacity.total(cap) == before
      refute_receive {:pushed, ^member, %{"type" => "chat.message"}}, 50

      # §14: a refused message is not an accepted one, so the deadline has not moved.
      assert snapshot(room_id).expires_at == deadline

      # And it consumed no sequence.
      assert {:ok, second} = chat(room_id, creator.sender_id, "next")
      assert second["sequence"] == first["sequence"] + 1
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC4 · evicted bytes go back to the global counter (§8)" do
    test "the counter tracks retained bytes, not bytes ever written" do
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_messages: 3)

      # Large messages first, then small ones. The sizes have to CHANGE for this to
      # test anything: with equal-sized messages every append nets to zero, so
      # neither the reserve nor the release path is exercised at all.
      for _ <- 1..3, do: {:ok, _} = chat(room_id, creator.sender_id, String.duplicate("x", 1_000))
      peak = Capacity.total(cap)

      for n <- 1..3, do: {:ok, _} = chat(room_id, creator.sender_id, "tiny #{n}")

      # Without releasing what it evicts, the relay leaks capacity until the room
      # dies — the counter would still be sitting at three kilobytes.
      assert Capacity.total(cap) < peak
      assert Capacity.total(cap) == retained_bytes(room_id)
    end

    test "a room that has evicted gives back exactly what it holds when it dies" do
      # `Capacity.release/2` moves two counters: the room's own row and the global
      # total. If the row is not brought down with it, the monitor hands back more
      # than the room ever held, and the global drifts BELOW the truth — the one
      # direction that admits past the cap.
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_messages: 2)

      for _ <- 1..2, do: {:ok, _} = chat(room_id, creator.sender_id, String.duplicate("x", 1_000))
      for n <- 1..3, do: {:ok, _} = chat(room_id, creator.sender_id, "tiny #{n}")

      pid = Rooms.whereis(room_id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert eventually(fn -> Capacity.total(cap) == 0 end)
    end

    test "an append that evicts as much as it adds succeeds with the counter at its cap" do
      # The whole reason eviction and the global cap have to be netted against each
      # other. A relay that reserved the new message's bytes BEFORE evicting would
      # refuse this — and would refuse it forever, because nothing about the room
      # changes until its TTL runs out 120 hours later. 128 rooms sitting at a 4 MiB
      # per-room cap is all it takes to fill the 512 MiB global one, so this is the
      # steady state under load, not a corner of it.
      sample = sample_size()

      # Room for three of these messages and comfortably short of a fourth.
      cap = capacity(div(7 * sample, 2))
      {room_id, creator} = create(capacity: cap, max_history_messages: 3)

      for n <- 1..3, do: {:ok, _} = chat(room_id, creator.sender_id, "sample")

      # Every message here is the same size, so the counter is now as full as three
      # messages can make it, and a fourth cannot be added without dropping one.
      full = Capacity.total(cap)
      assert full + div(full, 3) > Capacity.limit(cap)

      assert {:ok, _} = chat(room_id, creator.sender_id, "sample")
      assert length(texts(room_id)) == 3
      assert Capacity.total(cap) == full
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC5 · what eviction does to the snapshot (protocol V13, D9)" do
    test "the snapshot is sequence-ascending with a gap at the front" do
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_messages: 3)

      for n <- 1..5, do: {:ok, _} = chat(room_id, creator.sender_id, "m#{n}")

      joiner = snapshot(room_id)
      sequences = Enum.map(joiner.history, & &1["sequence"])

      assert sequences == [3, 4, 5]
      assert sequences == Enum.sort(sequences)
      assert hd(sequences) > 1, "eviction should have left a gap at the front"

      # D9 / V13: the boundary is the last retained sequence, which after eviction
      # is no longer "one less than the number of messages ever sent".
      assert joiner.snapshot_sequence == 5
    end

    test "a gapped snapshot is a frame the codec accepts" do
      cap = capacity(10_000_000)
      {room_id, creator} = create(capacity: cap, max_history_messages: 2)

      for n <- 1..6, do: {:ok, _} = chat(room_id, creator.sender_id, "m#{n}")

      frame = Jason.encode!(Frames.join_ok(Fixtures.uuid(), snapshot(room_id)))

      # V13 checks `history` is sequence-ascending and that `snapshot_sequence`
      # matches its last entry. Both must still hold once the gaps are real rather
      # than theoretical — the relay must not emit a snapshot its own validator,
      # or the Go client's, would reject.
      assert {:ok, _decoded} = Protocol.decode(:client, :text, frame)
    end
  end
end
