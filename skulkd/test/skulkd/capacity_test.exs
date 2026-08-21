defmodule Skulkd.CapacityTest do
  @moduledoc """
  ROJ-40 (M1-2) acceptance criteria: spec §8's hard bounds, one describe block per
  criterion.

  **Not `async`, and that is not incidental.** The active-room cap is a property of
  the one global `Skulkd.RoomRegistry`; a test that fills it would starve every
  concurrent test of room creation, and a concurrent test creating rooms would move
  the cap out from under this one.

  The global byte counter is injectable (`:capacity`) rather than a singleton, so a
  test can set a cap it can actually reach. The alternative — proving something
  about a 512 MiB default — is a test that allocates half a gigabyte to make its
  point. Caps here are sized from a *measured* message rather than a guessed one:
  the encoded size depends on the generated username and room id, and both vary in
  length.
  """
  use ExUnit.Case, async: false

  alias Skulkd.Capacity
  alias Skulkd.Clock
  alias Skulkd.Fixtures
  alias Skulkd.Limits
  alias Skulkd.MemberStub
  alias Skulkd.Room
  alias Skulkd.Rooms

  @ttl :timer.hours(120)

  # Spec §6.4 / protocol §4: <adjective>-<animal>-<two digits>. Asserted where the
  # A8 accounting test deletes the field, so that the deletion is never a no-op.
  @username ~r/^[a-z]+-[a-z]+-[0-9]{2}$/

  # Comfortably larger than any small message, comfortably under §4's 4096-byte
  # text bound — a message that cannot fit in a nearly-full counter.
  @oversized String.duplicate("x", 3_500)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A byte counter of this test's own, with a cap it can reach.
  defp capacity(limit) do
    name = :"capacity_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Capacity, name: name, limit: limit}, id: name))
    name
  end

  defp fake_time(ttl_ms \\ @ttl) do
    {:ok, clock} = Clock.Fake.start_link()
    {clock, [clock: Clock.Fake.fun(clock), timer: Skulkd.Timer.Manual, ttl_ms: ttl_ms]}
  end

  defp create(opts \\ []) do
    room_id = Fixtures.room_id()
    {:ok, session} = Rooms.create(room_id, Fixtures.password(), opts)
    {room_id, session}
  end

  # The room cap is global, and earlier tests leave rooms alive behind them, so a
  # test can only ever say "n more than whatever is already here".
  defp headroom(n), do: Registry.count(Skulkd.RoomRegistry) + n

  defp chat(room_id, sender_id, text, opts \\ []) do
    Room.send_chat(room_id, sender_id, Fixtures.uuid(), text, opts)
  end

  defp encoded_size(payload), do: byte_size(Jason.encode!(payload))

  # One small message's encoded size, measured rather than guessed.
  defp sample_size do
    {room_id, session} = create(capacity: capacity(10_000_000))
    {:ok, payload} = chat(room_id, session.sender_id, "message 00")
    encoded_size(payload)
  end

  # The monitor that releases a killed room's bytes runs in Skulkd.Capacity, so for
  # the crash path the release lands just after the :DOWN the test itself saw.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC1 · the active-room cap (§8)" do
    test "creating past the cap is server_capacity" do
      max = headroom(2)

      {_first, _} = create(max_rooms: max)
      {_second, _} = create(max_rooms: max)

      assert {:error, :server_capacity} =
               Rooms.create(Fixtures.room_id(), Fixtures.password(), max_rooms: max)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC2 · expired rooms are purged before anything is rejected (§8)" do
    test "the create rejected at the cap succeeds once the expired rooms are reaped" do
      {clock, opts} = fake_time()
      max = headroom(2)

      {_first, _} = create(opts ++ [max_rooms: max])
      {_second, _} = create(opts ++ [max_rooms: max])

      assert {:error, :server_capacity} =
               Rooms.create(Fixtures.room_id(), Fixtures.password(), opts ++ [max_rooms: max])

      Clock.Fake.advance(clock, @ttl + 1)

      assert {:ok, _session} =
               Rooms.create(Fixtures.room_id(), Fixtures.password(), opts ++ [max_rooms: max])

      # Purging is not silent deletion: §14's `room.expired` still reaches the
      # members of every room the purge reaped.
      assert_receive {:push, %{"type" => "room.expired"}}
      assert_receive {:push, %{"type" => "room.expired"}}
    end

    test "a live room is never evicted to admit another one (§8)" do
      max = headroom(2)

      {first, first_session} = create(max_rooms: max)
      {second, second_session} = create(max_rooms: max)

      assert {:error, :server_capacity} =
               Rooms.create(Fixtures.room_id(), Fixtures.password(), max_rooms: max)

      # Still there, and still working rooms — capacity pressure never costs
      # someone else their conversation.
      assert Rooms.whereis(first)
      assert Rooms.whereis(second)
      assert {:ok, _} = chat(first, first_session.sender_id, "still here")
      assert {:ok, _} = chat(second, second_session.sender_id, "so am I")
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC3 · the participant cap (§8: 32 per room)" do
    test "the 33rd joiner gets room_full and the other 32 keep chatting" do
      {room_id, creator} = create()

      # The creator is admitted by create itself (§6.1 step 10), so the room fills
      # with 31 more.
      for _ <- 1..31 do
        assert {:ok, _} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
      end

      assert {:ok, roster} = Room.participants(room_id)
      assert length(roster) == 32

      assert {:error, :room_full} =
               Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())

      # The room is unaffected: same roster, still talking.
      assert {:ok, ^roster} = Room.participants(room_id)
      assert {:ok, message} = chat(room_id, creator.sender_id, "thirty-two of us")
      assert message["text"] == "thirty-two of us"
    end

    test "the cap is configurable per room" do
      {room_id, _creator} = create(max_members: 2)

      assert {:ok, _} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())

      assert {:error, :room_full} =
               Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC4 · the global retained-history byte cap (§8)" do
    test "a message that would exceed the cap is server_capacity and is not stored" do
      cap = capacity(sample_size() * 3)
      {room_id, creator} = create(capacity: cap)

      assert {:ok, first} = chat(room_id, creator.sender_id, "small")
      assert {:error, :server_capacity} = chat(room_id, creator.sender_id, @oversized)

      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
      assert Enum.map(joiner.history, & &1["text"]) == ["small"]
      assert joiner.snapshot_sequence == first["sequence"]
    end

    test "a rejected message leaves the counter exactly where it started" do
      cap = capacity(sample_size() * 3)
      {room_id, creator} = create(capacity: cap)

      {:ok, _} = chat(room_id, creator.sender_id, "small")
      before = Capacity.total(cap)

      assert {:error, :server_capacity} = chat(room_id, creator.sender_id, @oversized)

      # Reserve-then-undo has to actually undo. A leaked reservation here is
      # permanent: nothing ever recomputes this counter from the rooms.
      assert Capacity.total(cap) == before
    end

    test "a rejected message consumes no sequence, refreshes no TTL, and reaches nobody" do
      {clock, time} = fake_time()
      cap = capacity(sample_size() * 3)
      {room_id, creator} = create(time ++ [capacity: cap])

      {:ok, first} = chat(room_id, creator.sender_id, "small")

      member = MemberStub.start()
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: member)
      deadline = joiner.expires_at

      # An hour on the fake clock, so a TTL refresh would be plainly visible.
      Clock.Fake.advance(clock, :timer.hours(1))
      assert {:error, :server_capacity} = chat(room_id, creator.sender_id, @oversized)

      # Nobody heard it.
      refute_receive {:pushed, ^member, %{"type" => "chat.message"}}, 50

      # §14: only an ACCEPTED chat message moves the deadline.
      {:ok, after_rejection} =
        Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())

      assert after_rejection.expires_at == deadline

      # And the next accepted message takes the sequence the rejected one never got.
      assert {:ok, second} = chat(room_id, creator.sender_id, "next")
      assert second["sequence"] == first["sequence"] + 1
    end

    test "expired rooms are purged before a chat message is rejected (§8)" do
      # The ticket's acceptance criteria name this only for room creation. §8 names
      # both: "Before rejecting work due to a global capacity limit, the relay MUST
      # purge expired rooms", and the bullets under it cover new room creation AND
      # existing room chat. The spec is the implementation authority.
      sample = sample_size()
      {clock, doomed_time} = fake_time()
      survivor_time = sharing(clock, @ttl * 10)

      # Room for the doomed room's large message and nothing else.
      cap = capacity(byte_size(@oversized) + sample + div(sample, 2))

      {doomed, doomed_creator} = create(doomed_time ++ [capacity: cap])
      {survivor, survivor_creator} = create(survivor_time ++ [capacity: cap])

      assert {:ok, _} = chat(doomed, doomed_creator.sender_id, @oversized)

      # No headroom left, and the only bytes that can be freed belong to a room
      # that has to be reaped first.
      Clock.Fake.advance(clock, @ttl + 1)

      assert {:ok, _} =
               chat(survivor, survivor_creator.sender_id, "after the purge",
                 clock: Clock.Fake.fun(clock)
               )

      assert_receive {:push, %{"type" => "room.expired"}}
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC5 · the counter settles exactly under concurrency (design A13)" do
    @tag timeout: 120_000
    test "rooms appending concurrently never exceed the cap and leak no reservations" do
      rooms = 24
      per_room = 40

      # Sized so the cap is crossed in the middle of the run: every sender is still
      # hammering the counter while it sits at the boundary, which is exactly where
      # check-then-act admits two writers at once.
      limit = div(rooms * per_room * sample_size(), 2)
      cap = capacity(limit)

      sessions =
        for _ <- 1..rooms do
          {room_id, session} = create(capacity: cap)
          {room_id, session.sender_id}
        end

      # A barrier, so the senders converge on the counter instead of straggling
      # through it one warm-up at a time.
      test_pid = self()

      tasks =
        for {room_id, sender_id} <- sessions do
          Task.async(fn ->
            send(test_pid, {:ready, self()})
            assert_receive :go, 30_000

            Enum.reduce(1..per_room, 0, fn n, total ->
              case chat(room_id, sender_id, "message #{n}") do
                {:ok, payload} -> total + encoded_size(payload)
                {:error, :server_capacity} -> total
              end
            end)
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _}, 30_000)
      for task <- tasks, do: send(task.pid, :go)

      accepted = tasks |> Task.await_many(60_000) |> Enum.sum()

      # The cap held, and every byte the counter holds is a byte some room actually
      # stored — no reservation survived its rejection.
      assert accepted <= limit
      assert Capacity.total(cap) == accepted

      # A run where nothing was ever rejected would satisfy both assertions above
      # while testing nothing at all.
      assert accepted < rooms * per_room * sample_size()
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC6 · what a message costs (amendment A8)" do
    test "the charge is the encoded size, and it includes sender_username" do
      cap = capacity(1_000_000)
      {room_id, creator} = create(capacity: cap)

      before = Capacity.total(cap)
      assert {:ok, payload} = chat(room_id, creator.sender_id, "hello")
      charged = Capacity.total(cap) - before

      assert charged == encoded_size(payload)

      # A8 captures the username at store time precisely because it is retained,
      # and what is retained is what is accounted for. An implementation that
      # measured the message without it would charge less than this.
      assert payload["sender_username"] =~ @username
      assert charged > encoded_size(Map.delete(payload, "sender_username"))
    end

    test "bytes are returned to the counter when a room expires" do
      {clock, time} = fake_time()
      cap = capacity(1_000_000)
      {room_id, creator} = create(time ++ [capacity: cap])

      {:ok, _} = chat(room_id, creator.sender_id, "hello")
      assert Capacity.total(cap) > 0

      pid = Rooms.whereis(room_id)
      ref = Process.monitor(pid)
      Clock.Fake.advance(clock, @ttl + 1)
      send(pid, :ttl_check)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert eventually(fn -> Capacity.total(cap) == 0 end)
    end

    test "bytes are returned even when the room is killed outright" do
      # `terminate/2` is not a cleanup hook you can rely on: a GenServer that is not
      # trapping exits never runs it when it is killed. If release lived only there,
      # a crashed room would leak its history bytes until the relay restarted — so a
      # monitor is the backstop, and this is the test that says so.
      cap = capacity(1_000_000)
      {room_id, creator} = create(capacity: cap)

      {:ok, _} = chat(room_id, creator.sender_id, "hello")
      assert Capacity.total(cap) > 0

      pid = Rooms.whereis(room_id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert eventually(fn -> Capacity.total(cap) == 0 end)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC7 · every bound is configurable and its default matches §8" do
    test "the defaults are the numbers in the table" do
      assert Limits.max_rooms() == 10_000
      assert Limits.max_members_per_room() == 32
      assert Limits.max_history_messages() == 1_000
      assert Limits.max_history_bytes() == 4 * 1024 * 1024
      assert Limits.max_total_history_bytes() == 512 * 1024 * 1024
      assert Limits.room_ttl_ms() == :timer.hours(120)
    end

    test "each one reads from application environment (§7.4)" do
      for {key, value, read} <- [
            {:max_rooms, 7, &Limits.max_rooms/0},
            {:max_members_per_room, 3, &Limits.max_members_per_room/0},
            {:max_history_messages, 11, &Limits.max_history_messages/0},
            {:max_history_bytes, 13, &Limits.max_history_bytes/0},
            {:max_total_history_bytes, 17, &Limits.max_total_history_bytes/0},
            {:room_ttl_ms, 19, &Limits.room_ttl_ms/0}
          ] do
        original = Application.fetch_env(:skulkd, key)
        Application.put_env(:skulkd, key, value)

        try do
          assert read.() == value
        after
          case original do
            {:ok, previous} -> Application.put_env(:skulkd, key, previous)
            :error -> Application.delete_env(:skulkd, key)
          end
        end
      end
    end

    test "a room with no explicit bounds takes them from configuration" do
      Application.put_env(:skulkd, :max_members_per_room, 1)
      on_exit(fn -> Application.delete_env(:skulkd, :max_members_per_room) end)

      {room_id, _creator} = create()

      assert {:error, :room_full} =
               Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
    end
  end

  # ---------------------------------------------------------------------------

  # Both rooms in the purge test share one clock — the survivor just holds a TTL
  # long enough to outlive the sweep that reaps the other.
  defp sharing(clock, ttl_ms) do
    [clock: Clock.Fake.fun(clock), timer: Skulkd.Timer.Manual, ttl_ms: ttl_ms]
  end
end
