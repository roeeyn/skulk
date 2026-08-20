defmodule Skulkd.Conn do
  @moduledoc """
  One WebSocket connection: validate inbound frames, drive `Skulkd.Rooms`, forward the
  room's pushes back out.

  This process IS the room member. `Skulkd.Room` monitors it, so an abrupt socket
  close — no close frame, no `terminate/2`, cable pulled — arrives at the room as a
  `:DOWN` and becomes a `presence.left` with no heartbeat, no reaper, and no
  bookkeeping here. That is the whole disconnect story.

  A connection belongs to at most one room, from the moment `create.ok` / `join.ok`
  goes out (decision D12: which is why `chat.send` carries no `room_id`).
  """

  @behaviour WebSock

  require Logger

  alias Skulkd.Frames
  alias Skulkd.Protocol
  alias Skulkd.Room
  alias Skulkd.Rooms

  defstruct room_id: nil, sender_id: nil

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_in({data, opcode: opcode}, state) do
    case Protocol.decode(:relay, opcode, data) do
      {:ok, frame} ->
        dispatch(frame, state)

      {:error, code, close?} ->
        # Best-effort correlation: a frame that failed a late rule (an oversized
        # text, say) still parsed and may carry a request_id worth echoing. One that
        # failed V3/V4 has nothing to echo, and that is fine — §5.11 makes
        # request_id present iff the answered frame carried one.
        respond_error(code, salvage_request_id(data), close?, state)
    end
  end

  @impl true
  def handle_info({:push, %{"type" => "room.expired"} = frame}, state) do
    # Spec §14: the room is gone. Deliver the notice, then close — there is nothing
    # left for this connection to do.
    {:stop, :normal, {1000, "room expired"}, [text(frame)], state}
  end

  def handle_info({:push, frame}, state), do: {:push, [text(frame)], state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state), do: {:ok, state}

  # --------------------------------------------------------------------------
  # Frame dispatch. Only c2r types reach here — V11 rejected the rest.
  # --------------------------------------------------------------------------

  defp dispatch(%{"type" => "create.begin"} = frame, state) do
    %{"room_id" => room_id, "password" => password} = frame["payload"]
    request_id = frame["request_id"]

    if joined?(state) do
      respond_error(:invalid_message, request_id, false, state)
    else
      case Rooms.create(room_id, password, member: self()) do
        {:ok, session} -> admitted(Frames.create_ok(request_id, session), session, state)
        {:error, code} -> respond_error(code, request_id, close?(code), state)
      end
    end
  end

  defp dispatch(%{"type" => "join.begin"} = frame, state) do
    %{"room_id" => room_id, "password" => password} = frame["payload"]
    request_id = frame["request_id"]

    if joined?(state) do
      respond_error(:invalid_message, request_id, false, state)
    else
      case Rooms.join(room_id, password, member: self()) do
        {:ok, session} -> admitted(Frames.join_ok(request_id, session), session, state)
        {:error, code} -> respond_error(code, request_id, close?(code), state)
      end
    end
  end

  defp dispatch(%{"type" => "chat.send"} = frame, state) do
    %{"message_id" => message_id, "text" => text} = frame["payload"]
    request_id = frame["request_id"]

    with_room(state, request_id, fn ->
      case Room.send_chat(state.room_id, state.sender_id, message_id, text) do
        # The room broadcasts to every member including this one (A11), so the
        # sender's copy arrives through handle_info like everyone else's. Replying
        # here as well would deliver it twice.
        {:ok, _payload} -> {:ok, state}
        {:error, code} -> respond_error(code, request_id, close?(code), state)
      end
    end)
  end

  defp dispatch(%{"type" => "presence.list"} = frame, state) do
    request_id = frame["request_id"]

    with_room(state, request_id, fn ->
      case Room.participants(state.room_id) do
        {:ok, participants} ->
          {:push, [text(Frames.presence_list(request_id, participants))], state}

        {:error, code} ->
          respond_error(code, request_id, close?(code), state)
      end
    end)
  end

  defp dispatch(%{"type" => "ping"} = frame, state) do
    # Spec §14: ping/pong never refreshes the room TTL and is never retained.
    {:push, [text(Frames.pong(frame["request_id"]))], state}
  end

  defp dispatch(%{"type" => "pong"}, state), do: {:ok, state}

  # --------------------------------------------------------------------------

  defp admitted(frame, session, state) do
    state = %{state | room_id: session.room_id, sender_id: session.sender_id}
    {:push, [text(frame)], state}
  end

  defp joined?(state), do: state.room_id != nil

  defp with_room(state, request_id, fun) do
    if joined?(state), do: fun.(), else: respond_error(:room_not_found, request_id, false, state)
  end

  defp respond_error(code, request_id, close?, state) do
    # §18.1: the code and nothing else. Never the frame, never a field of it.
    Logger.debug("rejecting frame: #{code}")

    frame = text(Frames.error(code, request_id))

    if close?,
      do: {:stop, :normal, {1002, to_string(code)}, [frame], state},
      else: {:push, [frame], state}
  end

  # §6: which semantic failures end the connection. Validation failures decide this
  # per rule instead — see Skulkd.Protocol.decode/3.
  defp close?(:room_expired), do: true
  defp close?(_code), do: false

  defp salvage_request_id(data) do
    with {:ok, %{"request_id" => id}} <- Jason.decode(data),
         true <- Protocol.valid_request_id?(id) do
      id
    else
      _ -> nil
    end
  end

  defp text(frame), do: {:text, Jason.encode!(frame)}
end
