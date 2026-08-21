defmodule Skulkd.Integration.AgentConversationTest do
  @moduledoc """
  The M0 milestone gate — and, by construction, the first agent-to-agent
  conversation skulk supports.

  ExUnit boots the relay in-process and drives real `skulk --headless` binaries
  through Ports (design A14: ExUnit drives everything). Two things follow from that
  arrangement, and both are the point:

  **These are the shipped binaries speaking the documented protocol**, so this suite
  is simultaneously the M0 gate and the compatibility suite for
  `docs/headless-v1.md` (amendment A15). If it passes, an AI agent works.

  **The relay is in this VM**, so a test can assert relay state directly rather than
  inferring it from what a client saw. That is the payoff of Elixir driving: "the
  join did not create a room" is checked by looking at the registry, not by
  squinting at an error message.
  """
  use ExUnit.Case, async: false

  alias Skulkd.Fixtures
  alias Skulkd.Room
  alias Skulkd.Rooms
  alias Skulkd.SkulkClient

  @moduletag :integration
  @moduletag timeout: 60_000

  setup do
    pid = start_supervised!({Bandit, plug: Skulkd.Router, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    on_exit(fn ->
      # No state leaks between tests: every room this test made is torn down, so a
      # later test cannot pass because of a room an earlier one left behind.
      for {_, room, _, _} <- DynamicSupervisor.which_children(Skulkd.RoomSupervisor) do
        DynamicSupervisor.terminate_child(Skulkd.RoomSupervisor, room)
      end
    end)

    %{server: "ws://127.0.0.1:#{port}/v1/ws"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp agent(server), do: SkulkClient.start(server)

  defp create(client, params \\ %{}) do
    SkulkClient.send_command(client, %{"id" => "c1", "command" => "create", "params" => params})
    {:ok, _} = SkulkClient.await(client, "connected")
    {:ok, created} = SkulkClient.await(client, "created")
    created["data"]
  end

  defp join(client, room_id, password, id \\ "j1") do
    SkulkClient.send_command(client, %{
      "id" => id,
      "command" => "join",
      "params" => %{"room_id" => room_id, "password" => password}
    })

    {:ok, _} = SkulkClient.await(client, "connected")
    SkulkClient.await(client, "joined")
  end

  defp say(client, text, id \\ "s1") do
    SkulkClient.send_command(client, %{
      "id" => id,
      "command" => "send",
      "params" => %{"text" => text}
    })

    {:ok, accepted} = SkulkClient.await(client, "accepted")
    accepted["data"]["message_id"]
  end

  defp who(client) do
    SkulkClient.send_command(client, %{"id" => "w1", "command" => "who", "params" => %{}})
    {:ok, roster} = SkulkClient.await(client, "participants")
    roster["data"]
  end

  defp quit(client) do
    SkulkClient.send_command(client, %{"id" => "q1", "command" => "quit", "params" => %{}})
    {:ok, _} = SkulkClient.await(client, "bye")
    {:ok, status} = SkulkClient.await_exit(client)
    status
  end

  # Polls a condition rather than sleeping a fixed amount: the client is a separate
  # OS process, so "has it exited yet" is inherently a question about wall clock.
  defp eventually(check, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if check.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  # ---------------------------------------------------------------------------

  describe "amendment A12: a departed name is not handed to someone else (ROJ-43)" do
    test "history stays attributed to who actually said it", %{server: server} do
      # Plumbing rather than the discriminator, and worth saying so: the namespace
      # is ninety thousand names, so "the new arrival did not happen to be given
      # the old one's name" would pass without the fix roughly 89,999 times in
      # 90,000. The unit suite injects a generator to make the relay's notion of
      # what is taken directly observable. What this adds is the end-to-end
      # attribution fact through real clients: A8 captures the sender's name into
      # the stored message, so it survives the sender leaving.
      alice = agent(server)
      room = create(alice)

      say(alice, "alice was here")
      alice_name = who(alice)["participants"] |> hd() |> Map.fetch!("username")
      quit(alice)

      bob = agent(server)
      {:ok, bob_session} = join(bob, room["room_id"], room["password"])
      assert eventually(fn -> length(who(bob)["participants"]) == 1 end)

      # The name is still in the transcript, so it is still spoken for.
      refute bob_session["data"]["username"] == alice_name

      say(bob, "bob is here now")

      carol = agent(server)
      {:ok, carol_session} = join(carol, room["room_id"], room["password"])
      history = carol_session["data"]["history"]

      # Two messages, each still attributed to whoever actually sent it — one of
      # them by someone who has already disconnected.
      assert Enum.map(history, & &1["text"]) == ["alice was here", "bob is here now"]

      assert Enum.map(history, & &1["sender_username"]) == [
               alice_name,
               bob_session["data"]["username"]
             ]

      # And nobody present is wearing a name the transcript already spends.
      present = Enum.map(who(carol)["participants"], & &1["username"])
      refute alice_name in present
      assert length(Enum.uniq(present)) == length(present)

      quit(bob)
      quit(carol)
    end
  end

  describe "the documented transcript (docs/headless-v1.md §13)" do
    test "two agents hold the conversation the specification describes", %{server: server} do
      alice = agent(server)

      # §4: ready is the first line, before any network activity.
      {:ok, ready} = SkulkClient.await(alice, "ready")
      assert ready["headless_version"] == 1
      assert ready["protocol_version"] == 0

      created = create(alice)

      # §5.1: the generated passphrase is RETURNED. Everything downstream depends on
      # a program being able to read it — this is what makes unattended create work.
      assert created["password"] =~ ~r/^[a-z-]+$/
      assert length(String.split(created["room_id"], "-")) == 8
      assert created["username"] =~ ~r/^[a-z]+-[a-z]+-[0-9]{2}$/
      assert created["sender_id"] =~ ~r/^[A-Za-z0-9_-]{22}$/
      assert created["expires_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
      refute Map.has_key?(created, "history"), "create.ok carries no history (protocol D8)"

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")
      {:ok, joined} = join(bob, created["room_id"], created["password"])

      assert joined["data"]["history"] == []
      assert joined["data"]["snapshot_sequence"] == 0
      assert length(joined["data"]["participants"]) == 2
      assert joined["id"] == "j1", "responses echo the command id"

      # Alice learns Bob arrived.
      {:ok, presence} = SkulkClient.await(alice, "presence")
      assert presence["data"]["action"] == "joined"
      assert presence["data"]["participant_count"] == 2

      message_id = say(alice, "hello from agent A")

      {:ok, alices_copy} = SkulkClient.await(alice, "message")
      {:ok, bobs_copy} = SkulkClient.await(bob, "message")

      # §5.3: `accepted` means on the wire; the echo carrying the same message_id
      # means stored at a sequence. That pairing is amendment A1d's
      # self-suppression check, handed to agents at M0.
      assert alices_copy["data"]["message_id"] == message_id
      assert alices_copy["data"]["self"] == true
      assert bobs_copy["data"]["self"] == false
      assert alices_copy["data"]["sequence"] == bobs_copy["data"]["sequence"]

      # A11: the two copies are identical apart from the locally-derived self flag.
      assert Map.delete(alices_copy["data"], "self") == Map.delete(bobs_copy["data"], "self")

      assert quit(bob) == 0
      {:ok, left} = SkulkClient.await(alice, "presence")
      assert left["data"]["action"] == "left"
      assert quit(alice) == 0
    end
  end

  describe "unicode in both directions" do
    test "emoji and CJK survive the round trip with consistent sequences", %{server: server} do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")
      created = create(alice)

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")
      {:ok, _} = join(bob, created["room_id"], created["password"])
      {:ok, _} = SkulkClient.await(alice, "presence")

      from_alice = "🦊 skulk 潜行 — a fox moves quietly"
      from_bob = "مرحبا 🌍 ここにいます"

      say(alice, from_alice)
      {:ok, a1} = SkulkClient.await(alice, "message")
      {:ok, b1} = SkulkClient.await(bob, "message")

      say(bob, from_bob, "s2")
      {:ok, b2} = SkulkClient.await(bob, "message")
      {:ok, a2} = SkulkClient.await(alice, "message")

      assert a1["data"]["text"] == from_alice
      assert b1["data"]["text"] == from_alice
      assert a2["data"]["text"] == from_bob
      assert b2["data"]["text"] == from_bob

      # Both clients agree on the ordering the relay assigned.
      assert a1["data"]["sequence"] == 1
      assert b1["data"]["sequence"] == 1
      assert a2["data"]["sequence"] == 2
      assert b2["data"]["sequence"] == 2
    end
  end

  describe "history" do
    test "a third client joining mid-conversation gets the whole transcript in order", %{
      server: server
    } do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")
      created = create(alice)

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")
      {:ok, _} = join(bob, created["room_id"], created["password"])
      {:ok, _} = SkulkClient.await(alice, "presence")

      for {text, n} <- Enum.with_index(["first", "second", "third", "fourth"], 1) do
        speaker = if rem(n, 2) == 1, do: alice, else: bob
        say(speaker, text, "s#{n}")
        {:ok, _} = SkulkClient.await(alice, "message")
        {:ok, _} = SkulkClient.await(bob, "message")
      end

      carol = agent(server)
      {:ok, _} = SkulkClient.await(carol, "ready")
      {:ok, joined} = join(carol, created["room_id"], created["password"], "j2")

      history = joined["data"]["history"]
      assert Enum.map(history, & &1["text"]) == ["first", "second", "third", "fourth"]
      assert Enum.map(history, & &1["sequence"]) == [1, 2, 3, 4]
      assert joined["data"]["snapshot_sequence"] == 4

      # Replayed history attributes correctly to whoever sent it (amendment A8).
      assert Enum.map(history, & &1["sender_username"]) |> Enum.uniq() |> length() == 2

      # /who from the newest client sees everyone, with distinct usernames (§6.4).
      roster = who(carol)
      assert roster["participant_count"] == 3
      usernames = Enum.map(roster["participants"], & &1["username"])
      assert length(Enum.uniq(usernames)) == 3
      assert Enum.all?(usernames, &(&1 =~ ~r/^[a-z]+-[a-z]+-[0-9]{2}$/))
    end

    test "rejoining after a quit is a fresh identity with the history replayed", %{server: server} do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")
      created = create(alice)

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")
      {:ok, first_join} = join(bob, created["room_id"], created["password"])
      {:ok, _} = SkulkClient.await(alice, "presence")

      say(alice, "before bob left")
      {:ok, _} = SkulkClient.await(alice, "message")
      {:ok, _} = SkulkClient.await(bob, "message")

      assert quit(bob) == 0
      {:ok, _} = SkulkClient.await(alice, "presence")

      # Spec §20: a reconnect is a FRESH join. New process, new connection, new
      # identity — not a resumption. Anything else would imply a continuity the
      # relay does not provide.
      bob_again = agent(server)
      {:ok, _} = SkulkClient.await(bob_again, "ready")
      {:ok, second_join} = join(bob_again, created["room_id"], created["password"], "j2")

      assert second_join["data"]["sender_id"] != first_join["data"]["sender_id"],
             "a rejoin must get a new sender_id"

      assert second_join["data"]["username"] != first_join["data"]["username"],
             "a rejoin must get a new username (§6.4: usernames are connection-scoped)"

      assert Enum.map(second_join["data"]["history"], & &1["text"]) == ["before bob left"],
             "the full retained history is re-delivered to the returning client"
    end
  end

  describe "failure paths" do
    test "a wrong password exits 5 and leaves the room untouched", %{server: server} do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")
      created = create(alice)

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")

      SkulkClient.send_command(bob, %{
        "id" => "j1",
        "command" => "join",
        "params" => %{"room_id" => created["room_id"], "password" => "definitely-not-it"}
      })

      {:ok, _} = SkulkClient.await(bob, "connected")
      {:ok, error} = SkulkClient.await(bob, "error")

      assert error["data"]["source"] == "wire"
      assert error["data"]["code"] == "authentication_failed"
      assert error["data"]["fatal"] == true
      assert error["id"] == "j1"
      assert {:ok, 5} = SkulkClient.await_exit(bob)

      # Asserted from inside the relay, which is the point of Elixir driving: the
      # failed attempt changed nothing.
      {:ok, participants} = Room.participants(created["room_id"])
      assert length(participants) == 1

      # And Alice never heard about it.
      SkulkClient.refute_event(alice, "presence")
    end

    test "joining a room that does not exist exits 4 and does NOT create it", %{server: server} do
      room_id = Fixtures.room_id()
      assert Rooms.whereis(room_id) == nil

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")

      SkulkClient.send_command(bob, %{
        "id" => "j1",
        "command" => "join",
        "params" => %{"room_id" => room_id, "password" => "correct-horse-battery"}
      })

      {:ok, _} = SkulkClient.await(bob, "connected")
      {:ok, error} = SkulkClient.await(bob, "error")

      assert error["data"]["code"] == "room_not_found"
      assert {:ok, 4} = SkulkClient.await_exit(bob)

      # The assertion a client-side test could not make: spec §6.2's "join MUST NOT
      # create a missing room", checked against the registry itself.
      assert Rooms.whereis(room_id) == nil
    end

    test "kill -9 removes the participant and tells everyone else", %{server: server} do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")
      created = create(alice)

      bob = agent(server)
      {:ok, _} = SkulkClient.await(bob, "ready")
      {:ok, joined} = join(bob, created["room_id"], created["password"])
      {:ok, _} = SkulkClient.await(alice, "presence")

      {:ok, participants} = Room.participants(created["room_id"])
      assert length(participants) == 2

      # No close frame, no goodbye, no chance to clean up — the process is simply
      # gone. This is the disconnect that matters, and the relay handles it with a
      # monitor rather than a heartbeat.
      os_pid = SkulkClient.os_pid(bob)
      {_output, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])

      {:ok, left} = SkulkClient.await(alice, "presence", 5_000)
      assert left["data"]["action"] == "left"
      assert left["data"]["sender_id"] == joined["data"]["sender_id"]
      assert left["data"]["participant_count"] == 1

      # No zombie: the relay's own view agrees with what it told Alice.
      {:ok, participants} = Room.participants(created["room_id"])
      assert length(participants) == 1
      refute joined["data"]["sender_id"] in Enum.map(participants, & &1["sender_id"])
    end
  end

  describe "process lifecycle" do
    test "closing the port ends the client (decision H2)", %{server: server} do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")
      created = create(alice)

      # Erlang has no "close stdin only": closing the port closes the pipes and the
      # client sees EOF on stdin. H2 defines that as `quit`, and it is the exact
      # shutdown path a supervising harness uses — which is why H2 exists rather
      # than leaving EOF to chance.
      #
      # The exit STATUS is not observable once the port is gone, so what is asserted
      # here is that the process terminates promptly. The `quit` command path
      # already pins exit 0.
      os_pid = SkulkClient.close_port(alice)

      assert eventually(fn -> not SkulkClient.alive?(os_pid) end),
             "the client should exit when its stdin closes"

      # And the relay noticed: no zombie participant left behind.
      assert eventually(fn -> match?({:ok, []}, Room.participants(created["room_id"])) end)
    end

    test "an agent that mistypes gets a diagnosis, not a hang-up", %{server: server} do
      alice = agent(server)
      {:ok, _} = SkulkClient.await(alice, "ready")

      # Not JSON at all — written raw, bypassing the encoder.
      SkulkClient.send_command(alice, %{"command" => "nonsense"})
      {:ok, error} = SkulkClient.await(alice, "error")
      assert error["data"]["source"] == "client"
      assert error["data"]["code"] == "invalid_command"
      assert error["data"]["fatal"] == false

      # Still usable: §7.1's rule that recoverable per-frame mistakes never close.
      created = create(alice)
      assert created["room_id"] != nil
      assert quit(alice) == 0
    end
  end
end
