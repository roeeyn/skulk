defmodule Skulkd.Room do
  @moduledoc """
  One room, one GenServer. Pure business logic — no sockets, no JSON encoding.
  ROJ-32 wires WebSockets to this.

  The process IS the room's concurrency control (spec §21). Sequence allocation,
  history insertion, participant changes, and the expiry check all run in the same
  serialized loop, so "race-safe" needs no locks and no ETS transactions — it needs
  one process. Creation is made atomic by `Registry`, not by this module: two
  simultaneous creates both try to register, and exactly one succeeds.

  Members are plain pids. The room monitors each one, pushes `{:push, frame}` to
  them, and treats `:DOWN` as a leave — so a crashed connection cleans itself up
  without a heartbeat or a reaper.

  Time is injected twice over (design A14): a clock for *what time is it* and a
  `Skulkd.Timer` for *wake me later*. See `Skulkd.Timer` for why one is not enough.
  """

  # :temporary — a room is never restarted. Its password hash and history live only
  # in this process, so a supervisor restart would resurrect the NAME with none of
  # the state behind it: a room nobody can authenticate against. Spec §14 makes the
  # same point about process death being the deletion mechanism.
  use GenServer, restart: :temporary

  require Logger

  alias Skulkd.Capacity
  alias Skulkd.Clock
  alias Skulkd.Frames
  alias Skulkd.Limits
  alias Skulkd.Username

  # Spec §9.2. Exact UTF-8 bytes: never trimmed, never normalized.
  @min_password_bytes 12
  @max_password_bytes 256

  # Protocol §4 / spec §9.1, decision D4: exactly eight lowercase ASCII words.
  @room_id_format ~r/^[a-z]+(-[a-z]+){7}$/
  @max_room_id_bytes 160

  defmodule State do
    @moduledoc false
    defstruct [
      :room_id,
      :password_hash,
      :ttl_ms,
      :clock,
      :timer,
      :expires_at,
      :capacity,
      :max_members,
      participants: %{},
      history: [],
      next_sequence: 1
    ]
  end

  # --------------------------------------------------------------------------
  # Client API
  # --------------------------------------------------------------------------

  @doc false
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: Skulkd.Rooms.via(room_id))
  end

  @doc """
  Stores a chat message and broadcasts it to every member, the sender included
  (amendment A11).

  This is the only operation that refreshes the room's TTL (spec §14).

  Runs in the caller's process up to the `GenServer.call`, which is what makes the
  §8 purge below safe — see `Skulkd.Rooms.purge_expired/1` for why a room must never
  make that call itself. `opts` carries `:clock` for that sweep.
  """
  @spec send_chat(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def send_chat(room_id, sender_id, message_id, text, opts \\ []) do
    request = {:send_chat, sender_id, message_id, text}

    case call(room_id, request) do
      {:error, :server_capacity} ->
        # §8: "Before rejecting work due to a global capacity limit, the relay MUST
        # purge expired rooms" — and the bullets under that sentence cover existing
        # room chat, not only new rooms. Expired rooms hold retained history that
        # still counts against the global cap, so the message that was just refused
        # may well fit once the dead rooms have let go of it. One retry, and only
        # when the sweep actually freed something.
        if Skulkd.Rooms.purge_expired(opts) > 0 do
          call(room_id, request)
        else
          {:error, :server_capacity}
        end

      result ->
        result
    end
  end

  @doc "The current roster — the wire form of `/who` (spec §6.3)."
  @spec participants(String.t()) :: {:ok, [map()]} | {:error, atom()}
  def participants(room_id), do: call(room_id, :participants)

  @doc "Removes a member and broadcasts `presence.left`. Idempotent."
  @spec leave(String.t(), String.t()) :: :ok | {:error, atom()}
  def leave(room_id, sender_id), do: call(room_id, {:leave, sender_id})

  defp call(room_id, message) do
    case Skulkd.Rooms.whereis(room_id) do
      nil -> {:error, :room_not_found}
      pid -> GenServer.call(pid, message)
    end
  catch
    # The room expired and stopped between the lookup and the call. Spec §21: a
    # request racing expiration must resolve one way or the other, never into a
    # partially deleted room.
    :exit, _ -> {:error, :room_not_found}
  end

  @doc false
  def validate_password(password) when is_binary(password) do
    case byte_size(password) do
      n when n < @min_password_bytes -> {:error, :invalid_message}
      n when n > @max_password_bytes -> {:error, :invalid_message}
      _ -> :ok
    end
  end

  def validate_password(_), do: {:error, :invalid_message}

  @doc false
  def validate_room_id(room_id) when is_binary(room_id) do
    if byte_size(room_id) <= @max_room_id_bytes and Regex.match?(@room_id_format, room_id) do
      :ok
    else
      {:error, :invalid_message}
    end
  end

  def validate_room_id(_), do: {:error, :invalid_message}

  # --------------------------------------------------------------------------
  # Server
  # --------------------------------------------------------------------------

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    clock = Keyword.get(opts, :clock, Clock.system())
    ttl_ms = Keyword.get_lazy(opts, :ttl_ms, &Limits.room_ttl_ms/0)
    capacity = Keyword.get(opts, :capacity, Capacity)

    state = %State{
      room_id: room_id,
      password_hash: Keyword.fetch!(opts, :password_hash),
      ttl_ms: ttl_ms,
      clock: clock,
      timer: Keyword.get(opts, :timer, Skulkd.Timer.System),
      expires_at: DateTime.add(clock.(), ttl_ms, :millisecond),
      capacity: capacity,
      max_members: Keyword.get_lazy(opts, :max_members, &Limits.max_members_per_room/0)
    }

    # Before a single byte is reserved, so that a room which dies early still has
    # something watching to give its bytes back.
    :ok = Capacity.track(capacity)

    # §18.1: room lifecycle may be logged, but with a truncated digest rather than
    # the room id itself — the id is an unlisted locator, and a log is not a place
    # to publish one.
    Logger.info("room created #{digest(room_id)}")

    {:ok, state |> publish_deadline() |> schedule_ttl_check()}
  end

  @impl true
  def handle_call(message, from, state) do
    if expired?(state) do
      {:stop, :normal, {:error, :room_expired}, expire(state)}
    else
      handle_live_call(message, from, state)
    end
  end

  defp handle_live_call({:admit, member_pid}, _from, state) do
    if map_size(state.participants) >= state.max_members do
      # Spec §8's participant cap. The room is untouched — a full room is a working
      # room, and §8 is explicit that capacity pressure never costs anyone already
      # here their conversation.
      {:reply, {:error, :room_full}, state}
    else
      admit_member(member_pid, state)
    end
  end

  defp handle_live_call({:send_chat, sender_id, message_id, text}, _from, state) do
    case Map.fetch(state.participants, sender_id) do
      :error ->
        {:reply, {:error, :room_not_found}, state}

      {:ok, sender} ->
        payload = %{
          "room_id" => state.room_id,
          "message_id" => message_id,
          "sender_id" => sender_id,
          "sender_username" => sender.username,
          "sequence" => state.next_sequence,
          "received_at" => Clock.to_wire(state.clock.()),
          "text" => text
        }

        # Spec §8's global retained-history bound. Reserved before anything in the
        # room changes, so a refusal costs nothing: no sequence consumed, no TTL
        # refreshed, nothing broadcast, nothing stored. Amendment A8's captured
        # `sender_username` is inside `payload` and is therefore accounted for — it
        # is retained, so it is charged.
        case Capacity.reserve(state.capacity, encoded_size(payload)) do
          {:error, :server_capacity} ->
            {:reply, {:error, :server_capacity}, state}

          :ok ->
            state =
              %{
                state
                | history: [payload | state.history],
                  next_sequence: state.next_sequence + 1,
                  # Spec §14: only a stored chat message refreshes the deadline.
                  # Joins, leaves, /who, and ping/pong deliberately do not.
                  expires_at: DateTime.add(state.clock.(), state.ttl_ms, :millisecond)
              }
              |> publish_deadline()

            broadcast(state, Frames.chat_message(payload))
            {:reply, {:ok, payload}, state}
        end
    end
  end

  # Verification lives in Skulkd.Rooms rather than here so that argon2's deliberate
  # slowness — tens of milliseconds — happens in the CALLER's process. Doing it
  # inside the room would serialize every joiner behind every other joiner's hash
  # and block chat traffic while it ran.
  defp handle_live_call(:password_hash, _from, state) do
    {:reply, {:ok, state.password_hash}, state}
  end

  # A room that is still alive has nothing to do here: the expiry guard in
  # handle_call/3 is the whole of the reaping. Spec §8 forbids evicting a live room
  # to make space, and this is the shape of that — a sweep can ask, and a live room
  # says no.
  defp handle_live_call(:reap, _from, state), do: {:reply, :ok, state}

  defp handle_live_call(:participants, _from, state) do
    {:reply, {:ok, roster(state)}, state}
  end

  defp handle_live_call({:leave, sender_id}, _from, state) do
    {:reply, :ok, remove(state, sender_id)}
  end

  defp admit_member(member_pid, state) do
    case Username.generate(usernames(state)) do
      {:ok, username} ->
        sender_id = new_sender_id()
        ref = Process.monitor(member_pid)

        participant = %{sender_id: sender_id, username: username, pid: member_pid, monitor: ref}
        state = put_in(state.participants[sender_id], participant)

        # Protocol §5.7: the joiner is not told about its own arrival — it already
        # has the full roster from create.ok/join.ok.
        broadcast(
          state,
          Frames.presence_joined(sender_id, username, map_size(state.participants)),
          except: sender_id
        )

        {:reply, {:ok, session(state, sender_id, username)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:ttl_check, state) do
    if expired?(state) do
      {:stop, :normal, expire(state)}
    else
      {:noreply, schedule_ttl_check(state)}
    end
  end

  # A member connection died. Spec §14 / A13: the monitor IS the cleanup mechanism.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.participants, fn {_id, p} -> p.monitor == ref end) do
      nil -> {:noreply, state}
      {sender_id, _} -> {:noreply, remove(state, sender_id, demonitor: false)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --------------------------------------------------------------------------
  # Internals
  # --------------------------------------------------------------------------

  defp expired?(state), do: DateTime.compare(state.clock.(), state.expires_at) != :lt

  defp expire(state) do
    expired_at = Clock.to_wire(state.clock.())
    broadcast(state, Frames.room_expired(state.room_id, expired_at))

    # Ordered before the caller's reply, which is what lets a §8 purge free bytes
    # and have the sweeper see them freed. The monitor in Skulkd.Capacity is the
    # backstop for the deaths that never reach this line at all.
    Capacity.release_all(state.capacity)

    Logger.info("room expired #{digest(state.room_id)}")
    state
  end

  # What this message costs the global counter: the bytes it will occupy in a
  # `join.ok` history snapshot, which is the thing §8 bounds.
  defp encoded_size(payload), do: byte_size(Jason.encode!(payload))

  # The deadline `Skulkd.Rooms.purge_expired/1` sweeps on. Only the registered
  # process may write its own registry value, so this has to happen in here — at
  # init, and again whenever an accepted message moves the deadline.
  defp publish_deadline(state) do
    Skulkd.Rooms.publish_deadline(state.room_id, state.expires_at)
    state
  end

  # Deadline-based rather than cancel-and-reschedule: the state holds the deadline,
  # a chat message moves it, and the tick simply asks whether we are past it. That
  # keeps refresh off the timer's critical path and makes the fake-timer test a
  # single `send(room, :ttl_check)`.
  defp schedule_ttl_check(state) do
    remaining = DateTime.diff(state.expires_at, state.clock.(), :millisecond)
    state.timer.send_after(self(), :ttl_check, max(remaining, 0))
    state
  end

  defp remove(state, sender_id, opts \\ []) do
    case Map.pop(state.participants, sender_id) do
      {nil, _} ->
        state

      {participant, participants} ->
        if Keyword.get(opts, :demonitor, true),
          do: Process.demonitor(participant.monitor, [:flush])

        state = %{state | participants: participants}

        broadcast(
          state,
          Frames.presence_left(sender_id, participant.username, map_size(participants))
        )

        state
    end
  end

  defp broadcast(state, frame, opts \\ []) do
    except = Keyword.get(opts, :except)

    for {sender_id, participant} <- state.participants, sender_id != except do
      send(participant.pid, {:push, frame})
    end

    :ok
  end

  defp session(state, sender_id, username) do
    %{
      room_id: state.room_id,
      sender_id: sender_id,
      username: username,
      expires_at: Clock.to_wire(state.expires_at),
      participants: roster(state),
      history: Enum.reverse(state.history),
      snapshot_sequence: state.next_sequence - 1
    }
  end

  defp roster(state) do
    state.participants
    |> Map.values()
    |> Enum.sort_by(& &1.username)
    |> Enum.map(&%{"sender_id" => &1.sender_id, "username" => &1.username})
  end

  defp usernames(state), do: Enum.map(Map.values(state.participants), & &1.username)

  # Protocol §4: 128 random bits, unpadded Base64URL — 22 characters.
  defp new_sender_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # Spec §18.1: a truncated digest, never the room id.
  defp digest(room_id) do
    :sha256
    |> :crypto.hash(room_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
