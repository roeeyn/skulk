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
      :max_history_messages,
      :max_history_bytes,
      :max_member_backlog,
      participants: %{},
      # Spec §15 appends at one end and evicts from the other, which is the one
      # access pattern a list cannot serve without walking it on every message.
      # `:queue` is O(1) at both, and `:queue.to_list/1` comes out oldest-first —
      # exactly the order a snapshot needs. Entries are `{payload, encoded_size}`:
      # eviction has to know what each message costs, and re-encoding to find out
      # would be both wasteful and a chance to disagree with what was charged.
      history: :queue.new(),
      history_count: 0,
      history_bytes: 0,
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
      max_members: Keyword.get_lazy(opts, :max_members, &Limits.max_members_per_room/0),
      max_history_messages:
        Keyword.get_lazy(opts, :max_history_messages, &Limits.max_history_messages/0),
      max_history_bytes: Keyword.get_lazy(opts, :max_history_bytes, &Limits.max_history_bytes/0),
      max_member_backlog:
        Keyword.get_lazy(opts, :max_member_backlog, &Limits.max_member_backlog/0)
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

        # Amendment A8's captured `sender_username` is inside `payload`, so it is
        # charged: what is retained is what is accounted for.
        store(state, payload, encoded_size(payload))
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

  # The order here is the whole of §8-meets-§15, and it is easy to get wrong.
  #
  # A room at its per-room cap makes room for each new message by evicting an old
  # one, so the append is close to free globally. Reserving the message's full size
  # before evicting would refuse it whenever the global counter is full — and refuse
  # it for the next 120 hours, because nothing about the room changes until its TTL
  # runs out. 128 rooms sitting at a 4 MiB per-room cap fill the 512 MiB global one,
  # so that is the steady state under load rather than a corner of it. §8 says chat
  # fails if accepting the message "would exceed" the global limit, and accepting it
  # includes the eviction §15 requires.
  #
  # So the eviction is planned first, without committing it, and only the NET change
  # is put to the counter. Planning rather than doing matters: if the counter refuses,
  # nothing has been evicted, and a message that could not be stored has not cost
  # anyone the history they already had.
  defp store(state, payload, size) do
    if size > state.max_history_bytes do
      # §15: refuse it rather than empty the room to fit it. No eviction, no
      # sequence consumed, no TTL refreshed, nothing broadcast.
      {:reply, {:error, :message_too_large}, state}
    else
      {kept, dropped, freed} = plan_eviction(state, size)
      delta = size - freed

      case reserve(state.capacity, delta) do
        {:error, :server_capacity} ->
          {:reply, {:error, :server_capacity}, state}

        :ok ->
          state =
            %{
              state
              | history: :queue.in({payload, size}, kept),
                history_count: state.history_count - dropped + 1,
                history_bytes: state.history_bytes - freed + size,
                next_sequence: state.next_sequence + 1,
                # Spec §14: only a stored chat message refreshes the deadline.
                # Joins, leaves, /who, and ping/pong deliberately do not.
                expires_at: DateTime.add(state.clock.(), state.ttl_ms, :millisecond)
            }
            |> publish_deadline()

          # Reserve before the commit, release after it, so that every transient
          # leaves the counter reading HIGH rather than low — refusing early is
          # recoverable, admitting past the cap is not.
          release(state.capacity, delta)

          state = broadcast(state, Frames.chat_message(payload))
          {:reply, {:ok, payload}, state}
      end
    end
  end

  defp reserve(capacity, delta) when delta > 0, do: Capacity.reserve(capacity, delta)
  defp reserve(_capacity, _delta), do: :ok

  defp release(capacity, delta) when delta < 0, do: Capacity.release(capacity, -delta)
  defp release(_capacity, _delta), do: :ok

  # Which of the oldest messages have to go for `incoming` to fit BOTH per-room
  # caps (§15), without touching the room's state. Returns the history that would
  # remain, and what dropping it would cost and free.
  defp plan_eviction(state, incoming) do
    evict(
      state.history,
      max(state.history_count + 1 - state.max_history_messages, 0),
      state.history_bytes + incoming - state.max_history_bytes,
      0,
      0
    )
  end

  defp evict(history, min_dropped, min_freed, dropped, freed)
       when dropped >= min_dropped and freed >= min_freed do
    {history, dropped, freed}
  end

  defp evict(history, min_dropped, min_freed, dropped, freed) do
    case :queue.out(history) do
      {{:value, {_payload, size}}, rest} ->
        evict(rest, min_dropped, min_freed, dropped + 1, freed + size)

      # Only reachable if a cap is configured at zero, which is not a room so much
      # as a refusal to have one. Stopping here keeps that a bad configuration
      # rather than a crashed room.
      {:empty, history} ->
        {history, dropped, freed}
    end
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
        #
        # The reply is built from the state this returns, not the one above it: if
        # announcing the arrival finds a member over the backlog bound, the joiner
        # must not be handed a roster containing someone everyone else just watched
        # leave.
        state =
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
    push_all(state, Frames.room_expired(state.room_id, expired_at))

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

        # The broadcast's result IS the return value. Announcing this departure can
        # itself find another member over the backlog bound, and dropping that one
        # has to survive back out through here — discarding this would kill their
        # process and leave them in the roster forever.
        broadcast(
          state,
          Frames.presence_left(sender_id, participant.username, map_size(participants))
        )
    end
  end

  @doc false
  # Fans a frame out to every member, and disconnects any that has fallen too far
  # behind (spec §21, design A13). Returns the state, because dropping a member
  # changes it — every caller must thread it through.
  #
  # **The bound is best-effort, and saying so is part of the design.**
  # `message_queue_len` is a snapshot, and frames beyond it sit in Bandit's socket
  # write buffer and the kernel's send buffer, neither of which the relay can see.
  # The guarantee is that runaway growth is cut off, not an exact byte ceiling. A
  # bound described as exact when it is approximate is worse than no bound, because
  # someone will reason about it.
  #
  # Healthy members are served BEFORE anyone is dropped: a member that cannot keep
  # up must not delay the ones that can, which is the whole point of §21.
  defp broadcast(state, frame, opts \\ []) do
    except = Keyword.get(opts, :except)

    {behind, keeping_up} =
      state.participants
      |> Enum.reject(fn {sender_id, _} -> sender_id == except end)
      |> Enum.split_with(fn {_, participant} ->
        behind?(participant, state.max_member_backlog)
      end)

    for {_sender_id, participant} <- keeping_up do
      send(participant.pid, {:push, frame})
    end

    Enum.reduce(behind, state, fn {sender_id, participant}, state ->
      disconnect(state, sender_id, participant)
    end)
  end

  # Fans out without checking anyone: the room is stopping, and a presence.left
  # nobody can act on immediately before `room.expired` is noise, not courtesy.
  defp push_all(state, frame) do
    for {_sender_id, participant} <- state.participants do
      send(participant.pid, {:push, frame})
    end

    :ok
  end

  defp behind?(participant, max_backlog) do
    case Process.info(participant.pid, :message_queue_len) do
      {:message_queue_len, queued} -> queued > max_backlog
      # Already gone. The monitor is what cleans that up; claiming it here would
      # race the :DOWN and double-announce the same departure.
      nil -> false
    end
  end

  defp disconnect(state, sender_id, participant) do
    # §18.1: the room's digest, never its id, and nothing about who was dropped.
    Logger.info("member disconnected for backlog #{digest(state.room_id)}")

    # `:kill` rather than anything gentler, for the same reason a close frame is
    # useless here: every other signal arrives through the mailbox, and the mailbox
    # is what is wedged. The member may even be mid-call to this room — its own
    # chat.send may be the broadcast that kills it — and the reply then goes
    # nowhere, which is a send into the void rather than a crash.
    Process.exit(participant.pid, :kill)

    remove(state, sender_id)
  end

  defp session(state, sender_id, username) do
    history = state.history |> :queue.to_list() |> Enum.map(&elem(&1, 0))

    %{
      room_id: state.room_id,
      sender_id: sender_id,
      username: username,
      expires_at: Clock.to_wire(state.expires_at),
      participants: roster(state),
      history: history,
      snapshot_sequence: last_sequence(history)
    }
  end

  # Decision D9 and rule V13: the boundary is the last RETAINED message's sequence,
  # or 0 for an empty snapshot.
  #
  # `next_sequence - 1` would still give the same answer, and a mutation pass says
  # so — §15 evicts only from the front, so the newest message always survives and
  # the last retained sequence is always the last accepted one. This reads it off
  # the history anyway, because that is the invariant V13 actually checks, and
  # stating it directly costs a list traversal a join already pays.
  defp last_sequence([]), do: 0
  defp last_sequence(history), do: history |> List.last() |> Map.fetch!("sequence")

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
