defmodule Skulkd.IdleTimeoutTest do
  @moduledoc """
  Pins the relay half of a real disconnect bug.

  Bandit closes an idle WebSocket with code **1002**, which reads like a protocol
  error but means "you went quiet" (`handle_timeout/2` in
  `bandit/websocket/connection.ex`). With a ten-minute bound and nothing sending
  keepalives, a session died of silence while the user was reading — reported from
  the field as `Disconnected: relay closed the connection (1002)`.

  Protocol v0 §5.10 specified ping/pong for exactly this and both sides implemented
  it; nothing ever sent one. The client now does (see `relay.DefaultKeepalive`), and
  these two tests pin the relay behaviour that fix depends on: silence is closed,
  pings prevent it.

  Not `async` — these manipulate application environment.
  """
  use ExUnit.Case, async: false

  alias Skulkd.WSClient

  @idle 1_500

  setup do
    previous = Application.get_env(:skulkd, :websocket_idle_timeout)
    Application.put_env(:skulkd, :websocket_idle_timeout, @idle)

    on_exit(fn ->
      if previous do
        Application.put_env(:skulkd, :websocket_idle_timeout, previous)
      else
        Application.delete_env(:skulkd, :websocket_idle_timeout)
      end
    end)

    pid = start_supervised!({Bandit, plug: Skulkd.Router, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{port: port}
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
  end

  defp ping(client) do
    {:ok, client} =
      WSClient.send_frame(client, %{
        "v" => 0,
        "type" => "ping",
        "request_id" => uuid(),
        "payload" => %{}
      })

    {:ok, client, pong} = WSClient.recv(client)
    assert pong["type"] == "pong"
    client
  end

  test "a silent connection is closed with 1002 — the bug, reproduced", %{port: port} do
    {:ok, client} = WSClient.connect(port)

    # Say nothing at all, which is what a user reading a long message looks like.
    assert {:closed, code, _reason} = WSClient.recv_close(client, @idle * 3)

    assert code == 1002,
           "Bandit's idle close code is what surfaces to users as a scary-looking " <>
             "protocol error; got #{inspect(code)}"
  end

  test "pings keep the connection alive past the idle timeout — the fix's premise", %{port: port} do
    {:ok, client} = WSClient.connect(port)

    # Ping across a window several times the idle timeout.
    client =
      Enum.reduce(1..6, client, fn _, client ->
        Process.sleep(div(@idle, 3))
        ping(client)
      end)

    # Still usable, well past the point where silence would have closed it.
    _client = ping(client)
  end
end
