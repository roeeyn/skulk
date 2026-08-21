defmodule Skulkd.Rooms do
  @moduledoc """
  The façade over the room supervision tree: create, join, look up.

  Creation atomicity (spec §21, §14) is bought with `Registry`, not with a lock.
  Both racers call `DynamicSupervisor.start_child/2`; both children try to register
  the same name in `init/1`; exactly one wins and the loser's process never
  finishes starting, so `start_child` answers `{:error, {:already_started, _}}`.
  There is no window in which a half-created room is joinable, because a room
  becomes reachable only by being registered.
  """

  alias Skulkd.Clock
  alias Skulkd.Limits
  alias Skulkd.Room

  @registry Skulkd.RoomRegistry
  @supervisor Skulkd.RoomSupervisor

  @type session :: %{
          room_id: String.t(),
          sender_id: String.t(),
          username: String.t(),
          expires_at: String.t(),
          participants: [map()]
        }

  @doc false
  def via(room_id), do: {:via, Registry, {@registry, room_id}}

  @doc """
  The room's pid, or `nil`.

  The liveness check is not paranoia. `Registry` unregisters a name when it
  processes the `:DOWN` for the dead owner, which happens asynchronously — so for a
  brief window after a room expires, a lookup still returns its pid. Callers that
  trusted it would send to a dead process and hit an exit rather than a clean
  `room_not_found`. Checking here means one place handles it instead of every
  caller; `Skulkd.Room.call/2` still catches the exit for the narrower race where
  the room dies between this check and the call itself.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  @doc """
  Creates a room and admits the creator in one step (spec §6.1 step 10).

  Options: `:member` (the pid to admit, default `self()`), `:ttl_ms`, `:clock`,
  `:timer`, `:capacity`, `:max_rooms`, `:max_members`.

  The returned session carries no `history`/`snapshot_sequence` — a new room has
  none by construction, and decision D8 keeps `create.ok` and `join.ok` distinct so
  a client cannot treat them as interchangeable.

  The capacity check sits ahead of `start_room/3` deliberately: that is where the
  password is hashed, and argon2 is expensive on purpose. Hashing for a room that
  cannot exist would hand an unauthenticated caller a CPU-burning primitive, which
  is the opposite of what a capacity bound is for.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, session()} | {:error, atom()}
  def create(room_id, password, opts \\ []) do
    with :ok <- Room.validate_room_id(room_id),
         :ok <- Room.validate_password(password),
         :ok <- room_capacity(opts),
         {:ok, pid} <- start_room(room_id, password, opts) do
      admit(pid, opts)
    end
  end

  @doc """
  Admits a member to an existing room.

  Never creates one (spec §6.2): an unknown room is `room_not_found`, full stop.
  A wrong password is the deliberately generic `authentication_failed` — nothing
  distinguishes it from any other credential failure.
  """
  @spec join(String.t(), String.t(), keyword()) :: {:ok, session()} | {:error, atom()}
  def join(room_id, password, opts \\ []) do
    with :ok <- Room.validate_room_id(room_id),
         :ok <- Room.validate_password(password),
         {:ok, pid} <- fetch(room_id),
         :ok <- verify(pid, password) do
      admit(pid, opts)
    end
  end

  @doc """
  Reaps every room whose deadline has passed, and answers how many it reaped.

  Spec §8 requires this before any global capacity limit rejects work — a relay
  that refused a room while holding thousands of dead ones would be enforcing a
  bound on the wrong number.

  **Runs in the caller's process, and the caller must never be a room.** Reaping is
  a `GenServer.call` into another room; a room that made that call could deadlock
  against a peer room making it back. The two call sites are `create/3` (called
  from a `Skulkd.Conn`) and `Skulkd.Room.send_chat/5` (which runs in its caller for
  exactly this reason). `self()` is excluded regardless, so the rule is enforced
  rather than merely documented.

  Candidates come from the deadline each room caches in its registry value, so the
  sweep reads one ETS table instead of asking ten thousand rooms how they are. A
  stale cache can only make it miss a candidate, never invent one: deadlines move
  forward only, and the room republishes when they do.
  """
  @spec purge_expired(keyword()) :: non_neg_integer()
  def purge_expired(opts \\ []) do
    clock = Keyword.get_lazy(opts, :clock, &Clock.system/0)
    now = DateTime.to_unix(clock.(), :millisecond)
    me = self()

    @registry
    |> Registry.select([{{:_, :"$1", :"$2"}, [{:<, :"$2", now}], [:"$1"]}])
    |> Enum.reject(&(&1 == me))
    |> Enum.count(&reap/1)
  end

  @doc false
  # Called by a room to publish its deadline for `purge_expired/1` to read. Only
  # the registered process may write its own value, which is why this is a room's
  # job rather than something done to it.
  @spec publish_deadline(String.t(), DateTime.t()) :: :ok
  def publish_deadline(room_id, %DateTime{} = expires_at) do
    at = DateTime.to_unix(expires_at, :millisecond)
    Registry.update_value(@registry, room_id, fn _ -> at end)
    :ok
  end

  # --------------------------------------------------------------------------

  # Bounded overshoot, accepted deliberately. Two creates that both read a count
  # one under the cap will both proceed, so a burst of N concurrent creators can
  # land N-1 rooms past it. Design A13 assigns reservation semantics to the global
  # *byte* counter, not to this: the registry is the authoritative room count and
  # self-cleans on room death, so nothing here can leak, and §2 principle 6 asks
  # for a bound rather than an exact one. A reserve-then-undo here would mean
  # starting a room and stopping it again — briefly publishing a joinable room that
  # is about to be killed, which is a worse failure than being a few over.
  defp room_capacity(opts) do
    max = Keyword.get_lazy(opts, :max_rooms, &Limits.max_rooms/0)
    active = Registry.count(@registry)

    cond do
      active < max -> :ok
      # `active` is read before the sweep and only what the sweep actually reaped is
      # credited back, so the arithmetic errs towards rejecting, never towards
      # admitting past the cap.
      active - purge_expired(opts) < max -> :ok
      true -> {:error, :server_capacity}
    end
  end

  # Any call into an expired room trips the expiry guard in Skulkd.Room, which
  # broadcasts `room.expired`, releases the room's history bytes, and stops — all
  # of it ordered before the reply lands here. §8: a purge is not silent deletion,
  # and it is not eviction either. Only rooms already past their deadline are
  # touched.
  defp reap(pid) do
    case GenServer.call(pid, :reap) do
      {:error, :room_expired} -> true
      _ -> false
    end
  catch
    # Already dying, for a reason that is not ours to claim credit for. Counting it
    # would risk admitting a room the cap should have refused; not counting it
    # costs at most one rejected create that the next attempt allows.
    :exit, _ -> false
  end

  defp start_room(room_id, password, opts) do
    child = {
      Room,
      [
        room_id: room_id,
        password_hash: Argon2.hash_pwd_salt(password)
      ] ++
        Keyword.take(opts, [
          :ttl_ms,
          :clock,
          :timer,
          :capacity,
          :max_members,
          :max_history_messages,
          :max_history_bytes,
          :max_member_backlog,
          :generate_username
        ])
    }

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :room_already_exists}
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  defp fetch(room_id) do
    case whereis(room_id) do
      nil -> {:error, :room_not_found}
      pid -> {:ok, pid}
    end
  end

  defp verify(pid, password) do
    case GenServer.call(pid, :password_hash) do
      {:ok, hash} ->
        if Argon2.verify_pass(password, hash), do: :ok, else: {:error, :authentication_failed}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _ -> {:error, :room_not_found}
  end

  defp admit(pid, opts) do
    member = Keyword.get(opts, :member, self())
    GenServer.call(pid, {:admit, member})
  catch
    :exit, _ -> {:error, :room_not_found}
  end

  defp translate({:shutdown, reason}), do: translate(reason)
  defp translate(reason) when is_atom(reason), do: reason
  defp translate(_), do: :internal_error
end
