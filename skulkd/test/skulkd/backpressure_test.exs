defmodule Skulkd.BackpressureTest do
  @moduledoc """
  ROJ-42 (M1-4) acceptance criteria: spec §21's bound on slow clients.

  > Slow clients MUST not block a room's broadcast loop indefinitely. Use bounded
  > outbound queues and disconnect clients that cannot keep up.

  A room used to `send/2` to every member and never look back. One consumer that
  stopped reading grew a mailbox without limit until the VM ran out of memory, and
  took the room's other members with it.

  The boundary is pinned with `MemberStub.wedge/2` rather than by flooding: the
  stub's receive matches `{:push, _}` and nothing else, so wedged junk counts
  toward `message_queue_len` while real pushes keep draining. That makes "one under
  the bound" and "one over it" two deterministic lines instead of a frame count and
  a sleep.
  """
  use ExUnit.Case, async: true

  alias Skulkd.Fixtures
  alias Skulkd.Limits
  alias Skulkd.MemberStub
  alias Skulkd.Room
  alias Skulkd.Rooms

  # ---------------------------------------------------------------------------

  # The creator is a stub rather than the test process, and that is not tidiness.
  # `Rooms.create/3` admits `self()` by default, so the test process would be a
  # room member — one that never drains the `{:push, _}` frames it is sent, and so
  # the first member this suite's own backlog bound catches. The relay killing the
  # test that is testing it is correct behaviour and a useless test.
  defp create(opts \\ []) do
    room_id = Fixtures.room_id()

    {:ok, session} =
      Rooms.create(room_id, Fixtures.password(), [member: MemberStub.start()] ++ opts)

    {room_id, session}
  end

  defp join(room_id) do
    member = MemberStub.start()
    {:ok, session} = Rooms.join(room_id, Fixtures.password(), member: member)
    MemberStub.settle(member)
    {member, session}
  end

  defp chat(room_id, sender_id, text \\ "hello") do
    Room.send_chat(room_id, sender_id, Fixtures.uuid(), text)
  end

  defp roster_ids(room_id) do
    {:ok, roster} = Room.participants(room_id)
    Enum.map(roster, & &1["sender_id"])
  end

  # ---------------------------------------------------------------------------
  describe "AC1 · a member that cannot keep up is disconnected (§21)" do
    test "the room drops it, kills it, and tells everyone else" do
      {room_id, creator} = create(max_member_backlog: 3)
      {slow, slow_session} = join(room_id)
      {witness, _} = join(room_id)

      MemberStub.wedge(slow, 4)
      assert {:ok, _} = chat(room_id, creator.sender_id, "the message that finds it")

      assert_receive {:pushed, ^witness,
                      %{"type" => "presence.left", "payload" => %{"sender_id" => left}}}

      assert left == slow_session.sender_id

      # Removing it from the roster without killing it would leave the wedged
      # connection alive and still growing — the exact leak this ticket exists to
      # stop. `Process.exit/2` with `:kill` is the only signal that does the job:
      # anything gentler arrives as a mailbox message, and the mailbox is what is
      # wedged.
      refute Process.alive?(slow)
    end

    test "the bound is a ceiling, not a target: at it, the member is kept" do
      {room_id, creator} = create(max_member_backlog: 3)
      {slow, slow_session} = join(room_id)

      MemberStub.wedge(slow, 3)
      assert {:ok, _} = chat(room_id, creator.sender_id, "still fine")

      assert Process.alive?(slow)
      assert slow_session.sender_id in roster_ids(room_id)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC2 · the other members keep receiving throughout" do
    test "a wedged member costs nobody else their messages" do
      # The property the whole ticket exists for.
      {room_id, creator} = create(max_member_backlog: 3)
      {slow, _} = join(room_id)
      {witness, _} = join(room_id)

      MemberStub.wedge(slow, 10)

      for n <- 1..5 do
        assert {:ok, _} = chat(room_id, creator.sender_id, "message #{n}")
      end

      texts =
        for _ <- 1..5 do
          assert_receive {:pushed, ^witness, %{"type" => "chat.message", "payload" => payload}}
          payload["text"]
        end

      assert texts == Enum.map(1..5, &"message #{&1}")
      refute Process.alive?(slow)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC3 · the room does not stall behind a slow member" do
    test "it keeps answering while a wedged member is being written to" do
      # Honest framing: `send/2` is asynchronous on the BEAM, so the room was never
      # at risk of blocking here the way the acceptance criterion's wording
      # suggests. What an unbounded mailbox actually costs is memory in the stalled
      # member, plus a scheduler penalty the runtime applies to whoever keeps
      # sending to a long queue. This is a responsiveness regression guard.
      {room_id, creator} = create(max_member_backlog: 100_000)
      {slow, _} = join(room_id)

      MemberStub.wedge(slow, 5_000)

      for n <- 1..20, do: {:ok, _} = chat(room_id, creator.sender_id, "message #{n}")

      assert {:ok, roster} = GenServer.call(Rooms.whereis(room_id), :participants, 1_000)
      assert length(roster) == 2
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC4 · no false positives on a brief hiccup" do
    test "a member that has caught up before the check is not disconnected" do
      {room_id, creator} = create(max_member_backlog: 3)
      {slow, slow_session} = join(room_id)

      MemberStub.wedge(slow, 10)
      MemberStub.drain(slow)
      MemberStub.settle(slow)

      assert {:ok, _} = chat(room_id, creator.sender_id, "after the hiccup")

      assert Process.alive?(slow)
      assert slow_session.sender_id in roster_ids(room_id)
      assert_receive {:pushed, ^slow, %{"type" => "chat.message"}}
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC5 · the relay's state matches what it told everyone" do
    test "a disconnected member is gone from the roster, with a count to match" do
      {room_id, creator} = create(max_member_backlog: 3)
      {slow, slow_session} = join(room_id)
      {witness, witness_session} = join(room_id)

      MemberStub.wedge(slow, 4)
      assert {:ok, _} = chat(room_id, creator.sender_id, "the message that finds it")

      assert_receive {:pushed, ^witness,
                      %{"type" => "presence.left", "payload" => %{"participant_count" => count}}}

      ids = roster_ids(room_id)
      refute slow_session.sender_id in ids
      assert witness_session.sender_id in ids
      assert creator.sender_id in ids
      assert count == length(ids)
    end

    test "a joiner's own roster never contains a member dropped while admitting it" do
      # The presence.joined broadcast for THIS join is what finds the wedged
      # member. If the reply is built from the state as it was before that
      # broadcast, the joiner is handed a roster containing someone everyone else
      # just watched leave — a zombie in the very frame that welcomes them.
      {room_id, _creator} = create(max_member_backlog: 3)
      {slow, slow_session} = join(room_id)

      MemberStub.wedge(slow, 4)

      {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())

      refute Enum.any?(joiner.participants, &(&1["sender_id"] == slow_session.sender_id))
      refute Process.alive?(slow)
    end

    test "a member found wedged while announcing someone else's departure is dropped too" do
      # The cascade. Announcing A's departure is what finds B over the bound, and
      # dropping B has to survive back out through the same call — a `remove/3`
      # that threw away the broadcast's result would kill B's process and leave B
      # in the roster forever.
      {room_id, creator} = create(max_member_backlog: 3)
      {leaver, leaver_session} = join(room_id)
      {slow, slow_session} = join(room_id)

      MemberStub.wedge(slow, 4)
      :ok = Room.leave(room_id, leaver_session.sender_id)

      ids = roster_ids(room_id)
      refute leaver_session.sender_id in ids
      refute slow_session.sender_id in ids
      assert ids == [creator.sender_id]
      refute Process.alive?(slow)
      assert Process.alive?(leaver)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC6 · the bound is configurable, and honest about what it is" do
    test "it defaults to 500 (§21, design A13)" do
      # Not one of §8's numbers — §21 asks for a bound and leaves the number to the
      # implementation, and A13 picked this one.
      assert Limits.max_member_backlog() == 500
    end

    test "a room takes it from its options" do
      {room_id, creator} = create(max_member_backlog: 1)
      {slow, _} = join(room_id)

      MemberStub.wedge(slow, 2)
      assert {:ok, _} = chat(room_id, creator.sender_id, "over an unusually low bound")

      refute Process.alive?(slow)
    end
  end
end
