defmodule Skulkd.Capacity do
  @moduledoc """
  The global retained-history byte counter (spec §8, design A13).

  ## Why this is not a GenServer call

  Every stored message has to be accounted for, so a counter that answered through
  a process mailbox would put one process in front of every message in the relay —
  the one global serialization point in a design whose whole point is a process per
  room. So `reserve/2` and `release_all/1` run **in the caller** and touch ETS
  directly. The GenServer here owns the table and does one job the table cannot do
  for itself: it monitors rooms, so a room that dies without a chance to tidy up
  still gives its bytes back.

  ## Reserve-then-undo, not check-then-act

  Design A13 is specific about the mechanism, and the reasoning is the interesting
  part. Rooms are independent processes, so "read the total, decide, then add" lets
  two rooms both read a total that leaves room for one more message and both store
  one. `:ets.update_counter/3` is atomic, so incrementing *first* makes the counter
  itself the arbiter: whoever pushes it past the cap is the one who gets rejected,
  and undoes their own increment.

  The visible cost is a transient over-count. While a doomed reservation is in
  flight, a concurrent `reserve/2` sees the inflated total and may be rejected
  though it would have fit. That direction is the safe one — the cap is never
  exceeded, only occasionally reached early — and it lasts for the two ETS
  operations between the increment and its undo.

  ## What a restart costs

  If this process crashes, its supervisor restarts it and the table is rebuilt
  empty: the total resets to zero and rooms' rows are gone. Live rooms keep working
  (`reserve/2` re-creates a missing row rather than raising, so one crash here does
  not cascade into every room in the relay) but their already-stored bytes are no
  longer counted, and the relay under-counts until those rooms die. Rebuilding the
  total by polling every room was rejected as machinery for a process that does
  almost nothing; the honest trade is written here instead.
  """

  use GenServer

  alias Skulkd.Limits

  # Row keys that are not pids. `:set` holds a mix happily, and keeping the two
  # scalars in the same table means `reserve/2` needs no second lookup elsewhere.
  @total :total
  @limit :limit

  @doc """
  Starts a counter.

  Options: `:name` (the process *and* table name, default `#{inspect(__MODULE__)}`)
  and `:limit` (default `Skulkd.Limits.max_total_history_bytes/0`).

  The name is an argument rather than a constant so a test can reach a cap. A test
  that had to spend 512 MiB to prove the cap works would be an allocation benchmark
  wearing a test's clothes.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reserves `bytes` against the cap, or refuses.

  Runs in the calling room's process. On `:ok` the caller now owns those bytes and
  gives them back by dying (the monitor) or by calling `release_all/1`.

  The global total moves before the room's own row does, and a room killed between
  those two operations leaves the global counter holding bytes no room's row claims
  — permanently, since nothing recomputes it. The order is that way round on
  purpose: reversed, the monitor would give back more than the room ever took and
  the counter would drift *below* the truth, quietly admitting more than the cap.
  Over-counting by at most one message per abnormally-killed room only ever refuses
  early, which is the direction a bound should fail in.
  """
  @spec reserve(atom(), pos_integer()) :: :ok | {:error, :server_capacity}
  def reserve(capacity, bytes) when is_integer(bytes) and bytes > 0 do
    if :ets.update_counter(capacity, @total, bytes, {@total, 0}) > limit(capacity) do
      :ets.update_counter(capacity, @total, -bytes, {@total, 0})
      {:error, :server_capacity}
    else
      :ets.update_counter(capacity, self(), bytes, {self(), 0})
      :ok
    end
  end

  @doc """
  Gives back everything the calling room holds.

  A room calls this on its way out so that the release is ordered *before* its
  final reply — which is what lets `Skulkd.Rooms.purge_expired/1` free bytes and
  have the caller see them freed. `:ets.take/2` is atomic, so the monitor in this
  module finding nothing left is the normal case rather than a race.
  """
  @spec release_all(atom()) :: :ok
  def release_all(capacity), do: release(capacity, self())

  @doc """
  Registers the calling room for cleanup on death.

  A `call`, not a `cast`: a room that reserved bytes before its monitor existed
  would leak them permanently if it crashed in that window.
  """
  @spec track(atom()) :: :ok
  def track(capacity), do: GenServer.call(capacity, {:track, self()})

  @doc "Bytes currently held across every room on this counter."
  @spec total(atom()) :: non_neg_integer()
  def total(capacity), do: :ets.lookup_element(capacity, @total, 2)

  @doc "The configured cap."
  @spec limit(atom()) :: pos_integer()
  def limit(capacity), do: :ets.lookup_element(capacity, @limit, 2)

  # --------------------------------------------------------------------------
  # Server
  # --------------------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    limit = Keyword.get_lazy(opts, :limit, &Limits.max_total_history_bytes/0)

    table =
      :ets.new(name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(table, [{@total, 0}, {@limit, limit}])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:track, pid}, _from, state) do
    # Monitor before the row exists, so a room that is already gone is cleaned up
    # by the :DOWN this call provokes rather than leaving a row behind forever.
    Process.monitor(pid)
    :ets.insert_new(state.table, {pid, 0})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    release(state.table, pid)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --------------------------------------------------------------------------

  defp release(capacity, pid) do
    case :ets.take(capacity, pid) do
      [{^pid, bytes}] when bytes > 0 ->
        :ets.update_counter(capacity, @total, -bytes, {@total, 0})
        :ok

      _ ->
        :ok
    end
  end
end
