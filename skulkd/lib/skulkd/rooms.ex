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
  `:timer`.

  The returned session carries no `history`/`snapshot_sequence` — a new room has
  none by construction, and decision D8 keeps `create.ok` and `join.ok` distinct so
  a client cannot treat them as interchangeable.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, session()} | {:error, atom()}
  def create(room_id, password, opts \\ []) do
    with :ok <- Room.validate_room_id(room_id),
         :ok <- Room.validate_password(password),
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

  # --------------------------------------------------------------------------

  defp start_room(room_id, password, opts) do
    child = {
      Room,
      [
        room_id: room_id,
        password_hash: Argon2.hash_pwd_salt(password)
      ] ++ Keyword.take(opts, [:ttl_ms, :clock, :timer])
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
