defmodule Skulkd.Integration.BackpressureTest do
  @moduledoc """
  ROJ-42 (M1-4) against a real socket, with a real client that has genuinely
  stopped reading.

  The unit suite wedges a stub's mailbox directly, which pins the boundary to the
  exact message but skips everything between the room and the network. This exists
  because that gap is where the honesty in the bound lives.

  **Stalling a real client means stopping the OS process.** `SIGSTOP` is the only
  way to make `skulk --headless` stop reading its socket while leaving the
  connection open — which is precisely the condition §21 is about. Then the kernel
  receive buffer fills, the relay's send buffer fills, Bandit's socket write
  finally blocks, and only *then* does the connection process's mailbox start to
  grow. Everything before that point is invisible to `message_queue_len`, which is
  exactly why design A13 insists the bound be described as best-effort rather than
  as a memory ceiling: hundreds of kilobytes can be in flight below the number the
  relay is checking.

  That is also why this test floods with maximum-size messages and lowers the bound
  — at a few bytes a frame it would take many thousands of them just to get the
  operating system's attention.
  """
  use ExUnit.Case, async: false

  alias Skulkd.Room
  alias Skulkd.SkulkClient

  @moduletag :integration
  @moduletag timeout: 300_000

  # High enough that a client which is merely busy never trips it — a healthy
  # client's backlog is bounded by how fast it writes, and stays far below this —
  # and low enough that a client which has stopped reading crosses it as soon as
  # the buffers below the relay are full.
  @bound 100

  # Protocol §4's ceiling on `text`, so each frame costs the buffers as much as the
  # protocol allows.
  @largest_text String.duplicate("x", 4_096)

  setup do
    previous = Application.get_env(:skulkd, :max_member_backlog)
    Application.put_env(:skulkd, :max_member_backlog, @bound)

    # A deliberately tiny send buffer. The relay cannot see a frame once the
    # operating system has taken it, so the bigger the kernel's buffers the more
    # data has to be pushed before `message_queue_len` moves at all — which is the
    # best-effort caveat, restated as a test-runner problem. Linux on loopback
    # auto-tunes these into the megabytes; macOS does not. Shrinking the buffer
    # does not change the mechanism under test, only how much shouting it takes to
    # reach it.
    pid =
      start_supervised!(
        {Bandit,
         plug: Skulkd.Router,
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: [sndbuf: 4_096, buffer: 4_096]]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    on_exit(fn ->
      if previous do
        Application.put_env(:skulkd, :max_member_backlog, previous)
      else
        Application.delete_env(:skulkd, :max_member_backlog)
      end

      for {_, room, _, _} <- DynamicSupervisor.which_children(Skulkd.RoomSupervisor) do
        DynamicSupervisor.terminate_child(Skulkd.RoomSupervisor, room)
      end
    end)

    %{server: "ws://127.0.0.1:#{port}/v1/ws"}
  end

  defp create(client) do
    SkulkClient.send_command(client, %{"id" => "c1", "command" => "create", "params" => %{}})
    {:ok, _} = SkulkClient.await(client, "connected")
    {:ok, created} = SkulkClient.await(client, "created")
    created["data"]
  end

  defp join(client, room_id, password) do
    SkulkClient.send_command(client, %{
      "id" => "j1",
      "command" => "join",
      "params" => %{"room_id" => room_id, "password" => password}
    })

    {:ok, _} = SkulkClient.await(client, "connected")
    {:ok, joined} = SkulkClient.await(client, "joined")
    joined["data"]
  end

  defp say(client, text, id) do
    SkulkClient.send_command(client, %{
      "id" => id,
      "command" => "send",
      "params" => %{"text" => text}
    })
  end

  defp eventually(check, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if check.(), do: {:halt, true}, else: Process.sleep(50) && {:cont, false}
    end)
  end

  defp participant_count(room_id) do
    case Room.participants(room_id) do
      {:ok, roster} -> length(roster)
      {:error, _} -> 0
    end
  end

  # ---------------------------------------------------------------------------

  test "a client that stops reading is dropped, and the one that kept up carries on",
       %{server: server} do
    talker = SkulkClient.start(server)
    room = create(talker)

    stalled = SkulkClient.start(server)
    join(stalled, room["room_id"], room["password"])
    stalled_os_pid = SkulkClient.os_pid(stalled)

    # Registered BEFORE the process is stopped, and not left to the end of the
    # test body: a failing assertion aborts the body, and a SIGSTOPped process
    # nothing ever continues survives the whole suite and wedges the next run.
    on_exit(fn ->
      System.cmd("kill", ["-CONT", Integer.to_string(stalled_os_pid)], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", Integer.to_string(stalled_os_pid)], stderr_to_stdout: true)
    end)

    assert eventually(fn -> participant_count(room["room_id"]) == 2 end)

    # From here it reads nothing. The socket stays open, which is the whole
    # difference between this and a client that simply crashed.
    {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(stalled_os_pid)])

    # Flooded adaptively rather than by a fixed count. How much data it takes to
    # fill the buffers below the relay is a property of the machine, not of the
    # relay, so this keeps shouting until the room notices or the budget runs out.
    dropped =
      Enum.reduce_while(1..60, false, fn batch, _ ->
        for n <- 1..50, do: say(talker, @largest_text, "flood-#{batch}-#{n}")

        cond do
          participant_count(room["room_id"]) == 1 -> {:halt, true}
          batch == 60 -> {:halt, false}
          true -> {:cont, false}
        end
      end)

    assert dropped, "the stalled client was never disconnected"

    # The room is intact and the client that kept up is still in it and still
    # talking — the property §21 exists to protect.
    SkulkClient.send_command(talker, %{"id" => "w1", "command" => "who", "params" => %{}})
    {:ok, roster} = SkulkClient.await(talker, "participants")
    assert length(roster["data"]["participants"]) == 1

    say(talker, "still here", "after")
    assert {:ok, _} = SkulkClient.await(talker, "accepted")

    # Relay state matches what it told everyone: no zombie left behind.
    assert participant_count(room["room_id"]) == 1
  end
end
