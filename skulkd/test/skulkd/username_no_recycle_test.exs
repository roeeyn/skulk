defmodule Skulkd.UsernameNoRecycleTest do
  @moduledoc """
  ROJ-43 (M1-5): amendment A12, now spec §6.4 after the v1.1 fold.

  ## The bug

  §6.4 makes usernames unique among *currently connected* participants, and A8
  captures the name into each stored message at send time. Put those together and
  `bright-fox-17` chats, leaves, someone new is assigned `bright-fox-17`, and a
  third person joins and sees the departed person's messages attributed to a name a
  different, present person is using right now.

  That is a correctness problem before it is a cosmetic one: at M4 the continuity
  fold binds `sender_username` precisely because it is relay-controlled and
  re-attributable, and this is the relay re-attributing by accident.

  ## Why these tests inject a generator

  The obvious test — "A leaves, B joins, assert B did not get A's name" — passes
  89,999 times in 90,000 **without the fix**, because the name is drawn at random
  from a namespace that large. It would be a green test for broken code.

  So the room takes `:generate_username` the same way it already takes `:clock`,
  `:timer` and `:capacity` (design A14: inject what you need to observe). The
  injected function here is a **pass-through recorder** — it reports the set it was
  handed and then calls the real generator — so every room invariant still holds
  while the thing under test, *what the room considers taken*, becomes something a
  test can assert on directly.
  """
  use ExUnit.Case, async: true

  alias Skulkd.Capacity
  alias Skulkd.Fixtures
  alias Skulkd.MemberStub
  alias Skulkd.Room
  alias Skulkd.Rooms
  alias Skulkd.Username

  # ---------------------------------------------------------------------------

  # Reports the taken-set to the test, then delegates. Recording rather than
  # replacing matters: a fake returning a fixed name would hand two members the
  # same username and quietly break the very guarantee this file is about.
  defp recorder do
    test = self()

    fn taken ->
      send(test, {:taken, MapSet.new(taken)})
      Username.generate(taken)
    end
  end

  defp create(opts \\ []) do
    room_id = Fixtures.room_id()

    {:ok, session} =
      Rooms.create(
        room_id,
        Fixtures.password(),
        [member: MemberStub.start(), generate_username: recorder()] ++ opts
      )

    {room_id, session}
  end

  defp join(room_id, opts \\ []) do
    {:ok, session} =
      Rooms.join(room_id, Fixtures.password(), [member: MemberStub.start()] ++ opts)

    session
  end

  defp chat(room_id, sender_id, text) do
    Room.send_chat(room_id, sender_id, Fixtures.uuid(), text)
  end

  # The set the room handed the generator for the most recent admission.
  defp taken_for_last_admission do
    assert_receive {:taken, taken}
    drain_taken(taken)
  end

  defp drain_taken(latest) do
    receive do
      {:taken, newer} -> drain_taken(newer)
    after
      0 -> latest
    end
  end

  defp history_names(room_id) do
    {:ok, joiner} = Rooms.join(room_id, Fixtures.password(), member: MemberStub.start())
    joiner.history |> Enum.map(& &1["sender_username"]) |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  describe "AC1 · a name in retained history is never handed out again (A12)" do
    test "the room counts history names as taken, not just connected ones" do
      {room_id, creator} = create()
      _ = taken_for_last_admission()

      talker = join(room_id)
      _ = taken_for_last_admission()

      {:ok, _} = chat(room_id, talker.sender_id, "I was here")
      :ok = Room.leave(room_id, talker.sender_id)

      # The talker is gone from the roster but its name is still in the transcript,
      # so the next admission must still be told the name is unavailable.
      _next = join(room_id)
      taken = taken_for_last_admission()

      assert MapSet.member?(taken, talker.username),
             "a name still in retained history was offered for reuse"

      assert MapSet.member?(taken, creator.username),
             "connected members must still be counted as taken"
    end

    test "the creator's own admission already sees an empty room correctly" do
      {_room_id, creator} = create()
      taken = taken_for_last_admission()

      # Nothing is connected and nothing is retained, so nothing is off limits.
      assert MapSet.size(taken) == 0
      assert creator.username =~ ~r/^[a-z]+-[a-z]+-[0-9]{2}$/
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC2 · a name becomes reusable once its messages are gone" do
    test "eviction frees the name it was holding" do
      # Reachable because of ROJ-41: before eviction, a name would be reserved for
      # the life of the room.
      cap = :"norecycle_#{System.unique_integer([:positive])}"
      start_supervised!(Supervisor.child_spec({Capacity, name: cap, limit: 10_000_000}, id: cap))

      {room_id, creator} = create(capacity: cap, max_history_messages: 2)
      _ = taken_for_last_admission()

      talker = join(room_id)
      _ = taken_for_last_admission()

      {:ok, _} = chat(room_id, talker.sender_id, "soon to be forgotten")
      :ok = Room.leave(room_id, talker.sender_id)

      _ = join(room_id)
      assert MapSet.member?(taken_for_last_admission(), talker.username)

      # Two more messages push the talker's only message out of the window.
      {:ok, _} = chat(room_id, creator.sender_id, "one")
      {:ok, _} = chat(room_id, creator.sender_id, "two")
      refute MapSet.member?(history_names(room_id), talker.username)

      _ = join(room_id)

      refute MapSet.member?(taken_for_last_admission(), talker.username),
             "a name whose messages were all evicted is still being reserved"
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC3 · the M0 guarantees still hold" do
    test "connected members never share a name" do
      {room_id, creator} = create()

      names = for _ <- 1..12, do: join(room_id).username
      all = [creator.username | names]

      assert length(Enum.uniq(all)) == length(all)
      assert Enum.all?(all, &(&1 =~ ~r/^[a-z]+-[a-z]+-[0-9]{2}$/))
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC4 · exhaustion is refused, not hung" do
    test "a room whose generator has nothing left refuses the join" do
      exhausted = fn _taken -> {:error, :no_username_available} end

      room_id = Fixtures.room_id()

      assert {:error, :no_username_available} =
               Rooms.create(room_id, Fixtures.password(),
                 member: MemberStub.start(),
                 generate_username: exhausted
               )
    end

    test "the refusal never reaches the wire as an unknown code" do
      # §6 registers exactly eleven error codes and BOTH codecs enum-validate the
      # field, so an `error` frame carrying `no_username_available` is one the
      # relay's own validator rejects — the relay breaking its own contract. The
      # path is unreachable in practice (ninety thousand names against a
      # thirty-two person room), which is exactly why nothing had noticed.
      frame = Skulkd.Frames.error(:no_username_available, Fixtures.uuid())

      assert frame["payload"]["code"] == "internal_error"
      assert frame["payload"]["code"] in Skulkd.Protocol.error_codes()
      assert {:ok, _} = Skulkd.Protocol.decode(:client, :text, Jason.encode!(frame))
    end
  end
end
