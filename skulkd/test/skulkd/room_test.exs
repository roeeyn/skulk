defmodule Skulkd.RoomTest do
  @moduledoc """
  ROJ-31 (M0-3) acceptance criteria, one describe block per criterion.

  `Skulkd.Room` is pure business logic — no sockets, no JSON. Members are plain pids
  that receive `{:push, frame}`, where `frame` is a protocol v0 envelope
  (docs/protocol-v0.md §5) as a string-keyed map. ROJ-32 wires those to WebSockets.

  Time is fully injected: `Skulkd.Clock.Fake` for "what time is it" and
  `Skulkd.Timer.Manual` for scheduling, because design A14 is explicit that an
  injected clock alone cannot fake `Process.send_after/3`. No test sleeps.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Skulkd.Clock
  alias Skulkd.Fixtures
  alias Skulkd.MemberStub
  alias Skulkd.Room
  alias Skulkd.Rooms

  @ttl :timer.hours(120)

  # The canonical wire timestamp, decision D5 in docs/protocol-v0.md: RFC 3339 UTC,
  # exactly three fractional digits, literal Z. Any other spelling is a corpus failure.
  @timestamp ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

  # Spec §6.4 / protocol §4: <adjective>-<animal>-<two digits>.
  @username ~r/^[a-z]+-[a-z]+-[0-9]{2}$/

  # Protocol §4: 128 random bits as unpadded Base64URL.
  @sender_id ~r/^[A-Za-z0-9_-]{22}$/

  defp fake_time do
    {:ok, clock} = Clock.Fake.start_link()
    {clock, [clock: Clock.Fake.fun(clock), timer: Skulkd.Timer.Manual, ttl_ms: @ttl]}
  end

  defp create(opts \\ []) do
    room_id = Fixtures.room_id()
    {:ok, session} = Rooms.create(room_id, Fixtures.password(), opts)
    {room_id, session}
  end

  # ---------------------------------------------------------------------------
  describe "AC1 · create, join, and the two ways a join fails" do
    test "create then join with the correct password admits the joiner" do
      {room_id, creator} = create()
      assert creator.room_id == room_id
      assert creator.sender_id =~ @sender_id
      assert creator.username =~ @username
      assert creator.expires_at =~ @timestamp

      assert creator.participants == [
               %{"sender_id" => creator.sender_id, "username" => creator.username}
             ]

      joiner_pid = MemberStub.start()
      assert {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: joiner_pid)

      assert joiner.sender_id =~ @sender_id
      assert joiner.sender_id != creator.sender_id
      assert joiner.username != creator.username
      assert joiner.history == []
      assert joiner.snapshot_sequence == 0
      assert length(joiner.participants) == 2
    end

    test "the wrong password is authentication_failed, and says nothing more" do
      {room_id, _} = create()
      assert {:error, :authentication_failed} = Rooms.join(room_id, "wrong-password-entirely")
    end

    test "joining an unknown room is room_not_found" do
      assert {:error, :room_not_found} = Rooms.join(Fixtures.room_id(), Fixtures.password())
    end

    test "a failed join NEVER creates the room" do
      room_id = Fixtures.room_id()
      assert {:error, :room_not_found} = Rooms.join(room_id, Fixtures.password())

      # If join had created it, this create would collide.
      assert {:ok, _} = Rooms.create(room_id, Fixtures.password())
    end

    test "creating a room that already exists is room_already_exists" do
      {room_id, _} = create()
      assert {:error, :room_already_exists} = Rooms.create(room_id, Fixtures.password())
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC2 · two simultaneous creates for one room id" do
    test "exactly one wins and the loser gets room_already_exists" do
      room_id = Fixtures.room_id()
      password = Fixtures.password()

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> Rooms.create(room_id, password, member: MemberStub.start()) end)
        end)
        |> Task.await_many(5_000)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, :room_already_exists}, &1))

      assert length(winners) == 1, "expected exactly one winner, got #{length(winners)}"
      assert length(losers) == 7

      assert length(winners) + length(losers) == length(results),
             "an unexpected error escaped: #{inspect(results)}"
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC3 · password bounds and exact bytes (spec §9.2)" do
    test "shorter than 12 UTF-8 bytes is rejected" do
      assert {:error, :invalid_message} =
               Rooms.create(Fixtures.room_id(), String.duplicate("a", 11))
    end

    test "exactly 12 bytes is accepted, exactly 256 is accepted, 257 is rejected" do
      assert {:ok, _} = Rooms.create(Fixtures.room_id(), String.duplicate("a", 12))
      assert {:ok, _} = Rooms.create(Fixtures.room_id(), String.duplicate("a", 256))

      assert {:error, :invalid_message} =
               Rooms.create(Fixtures.room_id(), String.duplicate("a", 257))
    end

    test "the bound counts BYTES, not characters" do
      # 11 characters, 33 UTF-8 bytes: accepted, because the bound is bytes.
      assert {:ok, _} = Rooms.create(Fixtures.room_id(), String.duplicate("潜", 11))

      # 86 characters, 258 bytes: rejected, for the same reason.
      assert {:error, :invalid_message} =
               Rooms.create(Fixtures.room_id(), String.duplicate("潜", 86))
    end

    test "a trailing space is part of the password and is not trimmed" do
      room_id = Fixtures.room_id()
      assert {:ok, _} = Rooms.create(room_id, "trailing-space-here ")

      assert {:error, :authentication_failed} = Rooms.join(room_id, "trailing-space-here")
      assert {:ok, _} = Rooms.join(room_id, "trailing-space-here ", member: MemberStub.start())
    end

    test "unicode passwords are not normalized" do
      room_id = Fixtures.room_id()
      # Same rendered text; different bytes (precomposed vs combining).
      precomposed = "café-au-lait-please"
      combining = "café-au-lait-please"
      refute precomposed == combining

      assert {:ok, _} = Rooms.create(room_id, precomposed)
      assert {:error, :authentication_failed} = Rooms.join(room_id, combining)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC4 · usernames (spec §6.4)" do
    test "are unique among connected members and match the required format" do
      {room_id, creator} = create()

      joiners =
        for _ <- 1..12 do
          {:ok, session} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
          session.username
        end

      names = [creator.username | joiners]
      assert Enum.all?(names, &(&1 =~ @username)), "bad format in #{inspect(names)}"
      assert length(Enum.uniq(names)) == length(names), "duplicate username in #{inspect(names)}"
    end

    test "are freed when a member leaves" do
      {room_id, _creator} = create()

      joiner_pid = MemberStub.start()
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: joiner_pid)
      :ok = Room.leave(room_id, joiner.sender_id)

      # The name is back in circulation: nothing holds it, so a later member may take it.
      {:ok, participants} = Room.participants(room_id)
      refute joiner.username in Enum.map(participants, & &1["username"])
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC5 · sequence allocation (spec §21)" do
    test "is strictly increasing and contiguous under concurrent senders" do
      {room_id, creator} = create()

      sequences =
        1..25
        |> Enum.map(fn n ->
          Task.async(fn ->
            {:ok, message} = Room.send_chat(room_id, creator.sender_id, uuid(), "message #{n}")
            message["sequence"]
          end)
        end)
        |> Task.await_many(5_000)
        |> Enum.sort()

      assert sequences == Enum.to_list(1..25)
    end

    test "a stored message carries the relay-assigned metadata in canonical form" do
      {room_id, creator} = create()
      message_id = uuid()

      {:ok, message} = Room.send_chat(room_id, creator.sender_id, message_id, "hello")

      assert message["room_id"] == room_id
      assert message["message_id"] == message_id
      assert message["sender_id"] == creator.sender_id
      assert message["sender_username"] == creator.username
      assert message["sequence"] == 1
      assert message["text"] == "hello"
      # Decision D5: exactly three fractional digits. DateTime.utc_now/0 emits six,
      # which would fail invalid/timestamp-wrong-precision.json once ROJ-32 validates.
      assert message["received_at"] =~ @timestamp
    end

    test "the sender receives its own message (amendment A11)" do
      {room_id, creator} = create()
      other = MemberStub.start()
      {:ok, _} = Rooms.join(room_id, Fixtures.password(), member: other)

      {:ok, _} = Room.send_chat(room_id, creator.sender_id, uuid(), "echo me")

      # The creator is this test process, so its push arrives directly.
      assert_receive {:push, %{"type" => "chat.message", "payload" => mine}}
      assert_receive {:pushed, ^other, %{"type" => "chat.message", "payload" => theirs}}

      # Byte-identical: at M4 the continuity fold treats any difference as tampering.
      assert mine == theirs
      assert mine["text"] == "echo me"
    end

    test "a chat from a non-member is rejected" do
      {room_id, _} = create()

      assert {:error, :room_not_found} =
               Room.send_chat(room_id, "notamemberatallxxxxxxx", uuid(), "hi")
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC6 · history snapshot on join (spec §15)" do
    test "returns every retained message, sequence-ascending" do
      {room_id, creator} = create()
      for n <- 1..5, do: {:ok, _} = Room.send_chat(room_id, creator.sender_id, uuid(), "m#{n}")

      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())

      assert Enum.map(joiner.history, & &1["sequence"]) == [1, 2, 3, 4, 5]
      assert Enum.map(joiner.history, & &1["text"]) == ~w(m1 m2 m3 m4 m5)
      assert joiner.snapshot_sequence == 5
    end

    test "a message sent after the snapshot boundary arrives live, exactly once" do
      {room_id, creator} = create()
      {:ok, _} = Room.send_chat(room_id, creator.sender_id, uuid(), "before")

      joiner_pid = MemberStub.start()
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: joiner_pid)
      assert joiner.snapshot_sequence == 1

      after_id = uuid()
      {:ok, _} = Room.send_chat(room_id, creator.sender_id, after_id, "after")

      assert_receive {:pushed, ^joiner_pid, %{"type" => "chat.message", "payload" => payload}}
      assert payload["message_id"] == after_id
      assert payload["sequence"] == 2

      # Exactly once: the boundary message is not also replayed.
      refute Enum.any?(joiner.history, &(&1["message_id"] == after_id))
      refute_receive {:pushed, ^joiner_pid, %{"payload" => %{"message_id" => ^after_id}}}, 50
    end

    test "presence events are never retained as history" do
      {room_id, creator} = create()
      {:ok, _} = Room.send_chat(room_id, creator.sender_id, uuid(), "only me")

      {:ok, _} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
      {:ok, third} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())

      assert length(third.history) == 1
      assert Enum.all?(third.history, &(&1["text"] == "only me"))
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC7 · presence" do
    test "presence.joined goes to the other members, not the joiner" do
      {room_id, _creator} = create()
      joiner_pid = MemberStub.start()

      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: joiner_pid)

      # The creator (this process) sees it...
      assert_receive {:push, %{"type" => "presence.joined", "payload" => payload}}
      assert payload["sender_id"] == joiner.sender_id
      assert payload["username"] == joiner.username
      assert payload["participant_count"] == 2

      # ...and the joiner does not: it learned the roster from join.ok (protocol §5.7).
      refute_receive {:pushed, ^joiner_pid, %{"type" => "presence.joined"}}, 50
    end

    test "killing a member removes it and broadcasts presence.left" do
      {room_id, _creator} = create()
      joiner_pid = MemberStub.start()
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: joiner_pid)
      assert_receive {:push, %{"type" => "presence.joined"}}

      Process.exit(joiner_pid, :kill)

      assert_receive {:push, %{"type" => "presence.left", "payload" => payload}}, 1_000
      assert payload["sender_id"] == joiner.sender_id
      assert payload["username"] == joiner.username
      assert payload["participant_count"] == 1

      {:ok, participants} = Room.participants(room_id)
      assert length(participants) == 1
    end

    test "an explicit leave broadcasts presence.left too" do
      {room_id, _creator} = create()
      joiner_pid = MemberStub.start()
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: joiner_pid)
      assert_receive {:push, %{"type" => "presence.joined"}}

      :ok = Room.leave(room_id, joiner.sender_id)

      assert_receive {:push,
                      %{"type" => "presence.left", "payload" => %{"participant_count" => 1}}}
    end

    test "participants/1 reflects joins and leaves (the wire form of /who)" do
      {room_id, creator} = create()
      {:ok, participants} = Room.participants(room_id)
      assert participants == [%{"sender_id" => creator.sender_id, "username" => creator.username}]

      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
      {:ok, participants} = Room.participants(room_id)
      assert length(participants) == 2

      :ok = Room.leave(room_id, joiner.sender_id)
      {:ok, participants} = Room.participants(room_id)
      assert length(participants) == 1
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC8 · TTL (spec §14), on a fake clock" do
    test "expiry broadcasts room.expired, stops the room, and deregisters it" do
      {clock, opts} = fake_time()
      {room_id, _creator} = create(opts)
      room = Rooms.whereis(room_id)
      ref = Process.monitor(room)

      Clock.Fake.advance(clock, @ttl + 1)
      send(room, :ttl_check)

      assert_receive {:push, %{"type" => "room.expired", "payload" => payload}}
      assert payload["room_id"] == room_id
      assert payload["expired_at"] =~ @timestamp

      assert_receive {:DOWN, ^ref, :process, ^room, :normal}
      assert Rooms.whereis(room_id) == nil
      assert {:error, :room_not_found} = Rooms.join(room_id, Fixtures.password())
    end

    test "an accepted chat message refreshes the TTL" do
      {clock, opts} = fake_time()
      {room_id, creator} = create(opts)
      room = Rooms.whereis(room_id)

      # Most of the way to the deadline, then a message resets it.
      Clock.Fake.advance(clock, @ttl - 1_000)
      {:ok, _} = Room.send_chat(room_id, creator.sender_id, uuid(), "still here")

      # Past the ORIGINAL deadline, but not the refreshed one.
      Clock.Fake.advance(clock, 2_000)
      send(room, :ttl_check)

      refute_receive {:push, %{"type" => "room.expired"}}, 50
      assert Process.alive?(room)
    end

    test "joins, leaves, and /who do NOT refresh the TTL" do
      {clock, opts} = fake_time()
      {room_id, _creator} = create(opts)
      room = Rooms.whereis(room_id)

      Clock.Fake.advance(clock, @ttl - 1_000)

      # Everything here is explicitly non-refreshing per spec §14.
      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
      {:ok, _} = Room.participants(room_id)
      :ok = Room.leave(room_id, joiner.sender_id)

      Clock.Fake.advance(clock, 2_000)
      send(room, :ttl_check)

      assert_receive {:push, %{"type" => "room.expired"}}
    end

    test "expiry is checked lazily on lookup, without waiting for the timer" do
      {clock, opts} = fake_time()
      {room_id, _creator} = create(opts)

      # No :ttl_check is ever delivered — correctness must not depend on scheduling.
      Clock.Fake.advance(clock, @ttl + 1)

      assert {:error, :room_expired} = Rooms.join(room_id, Fixtures.password())
    end

    test "a chat racing expiry fails with room_expired rather than being stored" do
      {clock, opts} = fake_time()
      {room_id, creator} = create(opts)

      Clock.Fake.advance(clock, @ttl + 1)

      assert {:error, :room_expired} =
               Room.send_chat(room_id, creator.sender_id, uuid(), "too late")
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC9 · logging (spec §18.1)" do
    test "no password, hash, room id, or message text reaches the log" do
      password = "unmistakable-password-9f2c"
      text = "unmistakable-message-body-4a7e"

      log =
        capture_log(fn ->
          room_id = Fixtures.room_id()
          {:ok, creator} = Rooms.create(room_id, password)
          {:ok, _} = Rooms.join(room_id, password, member: MemberStub.start())
          {:ok, _} = Room.send_chat(room_id, creator.sender_id, uuid(), text)
          :ok = Room.leave(room_id, creator.sender_id)

          # The room id itself is sensitive: §18.1 requires a truncated digest instead.
          send(self(), {:room_id, room_id})
        end)

      assert_received {:room_id, room_id}

      # Prove the assertions below are not vacuous: something WAS logged, and the
      # room is identified by the truncated digest §18.1 asks for.
      assert log =~ "room created"
      assert log =~ digest(room_id)

      refute log =~ password
      refute log =~ text
      refute log =~ room_id
      refute log =~ "argon2"
      refute log =~ "$argon2id$"
    end
  end

  # ---------------------------------------------------------------------------

  # The same truncated digest Skulkd.Room logs (spec §18.1).
  defp digest(room_id) do
    :sha256 |> :crypto.hash(room_id) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  # A canonical lowercase UUIDv4: version nibble 4, variant bits 10, per protocol §4.
  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
  end
end
