defmodule Skulkd.SkulkClient do
  @moduledoc """
  Drives a real `skulk --headless` process from ExUnit, over a Port.

  This is the harness design amendment A14 settles on: **ExUnit drives everything.**
  The relay boots in-process so tests can assert relay state directly, and the
  clients are the actual shipped binaries speaking the actual documented protocol —
  so this suite is simultaneously the M0 gate and the compatibility suite for
  `docs/headless-v1.md` (A15). If it passes, an AI agent works.

  Two details are load-bearing, both learned the hard way in ROJ-33:

  **Reading is continuous, not on demand.** A GenServer owns the port and drains
  every line into a queue as it arrives. `skulk` waits for its event pump to finish
  before exiting, so a harness that only read when it wanted something would block
  the client from exiting at all.

  **Lines are reassembled by hand, never by `{:line, n}`.** A `joined` event carries
  the room's whole retained history on one line — up to 4 MiB at spec §8's caps —
  and `{:line, n}` silently truncates at `n` (docs/headless-v1.md decision H3).
  """

  use GenServer

  @default_timeout 10_000

  defmodule State do
    @moduledoc false
    defstruct [:port, buffer: "", events: [], waiting: nil, exit_status: nil, exit_waiter: nil]
  end

  # --------------------------------------------------------------------------
  # API
  # --------------------------------------------------------------------------

  @doc """
  Starts `skulk --headless` pointed at `server`.

  The relay URL travels on argv because it is not a secret. The password never
  does — it arrives as JSON on stdin, which is amendment A15's rule and something
  the client enforces by refusing a `--password` flag outright.
  """
  def start(server) do
    {:ok, pid} = GenServer.start_link(__MODULE__, server)
    pid
  end

  @doc "Sends one command object; it is encoded as a single JSON line."
  def send_command(pid, command) when is_map(command) do
    GenServer.call(pid, {:send, Jason.encode!(command)})
  end

  @doc """
  Returns the next event of the given kind, buffering the others.

  Buffering matters: `docs/headless-v1.md` §11 promises no ordering between
  unsolicited events and command responses, so a harness that discarded
  non-matching events would consume an echo it later waits for and hang.
  """
  def await(pid, event, timeout \\ @default_timeout) do
    GenServer.call(pid, {:await, event, timeout}, timeout + 1_000)
  end

  @doc "Asserts no event of this kind arrives within `timeout`."
  def refute_event(pid, event, timeout \\ 300) do
    case GenServer.call(pid, {:await, event, timeout}, timeout + 1_000) do
      {:error, :timeout} -> :ok
      {:ok, unexpected} -> raise "expected no #{event} event, got #{inspect(unexpected)}"
    end
  end

  @doc "Waits for the process to exit and returns its exit status."
  def await_exit(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, {:await_exit, timeout}, timeout + 1_000)
  end

  @doc "The client's OS pid, for tests that need to kill it uncleanly."
  def os_pid(pid), do: GenServer.call(pid, :os_pid)

  @doc """
  Closes the port, which is how a supervising Elixir process shuts a client down.

  Erlang has no "close stdin only" for ports — closing the port closes the pipes,
  and the client sees EOF on stdin. That is exactly the case decision H2 exists to
  define, and it is the shutdown path this harness itself uses.

  Returns the OS pid, because once the port is closed its exit status is no longer
  deliverable: what remains observable is that the process terminates.
  """
  def close_port(pid), do: GenServer.call(pid, :close_port)

  @doc "Whether an OS process still exists."
  def alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  # --------------------------------------------------------------------------
  # Server
  # --------------------------------------------------------------------------

  @impl true
  def init(server) do
    binary = System.get_env("SKULK_BIN") || Mix.raise("SKULK_BIN is not set")

    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :hide,
        args: ["--headless", "--server", server]
      ])

    {:ok, %State{port: port}}
  end

  @impl true
  def handle_call({:send, line}, _from, state) do
    Port.command(state.port, line <> "\n")
    {:reply, :ok, state}
  end

  def handle_call({:await, event, timeout}, from, state) do
    case take(state.events, event) do
      {nil, _} ->
        timer = Process.send_after(self(), {:await_timeout, from}, timeout)
        {:noreply, %{state | waiting: {from, event, timer}}}

      {found, rest} ->
        {:reply, {:ok, found}, %{state | events: rest}}
    end
  end

  def handle_call({:await_exit, timeout}, from, state) do
    case state.exit_status do
      nil ->
        Process.send_after(self(), {:exit_timeout, from}, timeout)
        {:noreply, %{state | exit_waiter: from}}

      status ->
        {:reply, {:ok, status}, state}
    end
  end

  def handle_call(:os_pid, _from, state) do
    {:os_pid, os_pid} = Port.info(state.port, :os_pid)
    {:reply, os_pid, state}
  end

  def handle_call(:close_port, _from, state) do
    {:os_pid, os_pid} = Port.info(state.port, :os_pid)
    Port.close(state.port)
    {:reply, os_pid, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)
    events = state.events ++ Enum.map(lines, &Jason.decode!/1)
    {:noreply, deliver(%{state | buffer: buffer, events: events})}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    state = %{state | exit_status: status}

    if state.exit_waiter do
      GenServer.reply(state.exit_waiter, {:ok, status})
      {:noreply, %{state | exit_waiter: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:await_timeout, from}, state) do
    case state.waiting do
      {^from, _event, _timer} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:exit_timeout, from}, state) do
    if state.exit_waiter == from do
      GenServer.reply(from, {:error, :timeout})
      {:noreply, %{state | exit_waiter: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --------------------------------------------------------------------------

  defp deliver(%State{waiting: {from, event, timer}} = state) do
    case take(state.events, event) do
      {nil, _} ->
        state

      {found, rest} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, found})
        %{state | events: rest, waiting: nil}
    end
  end

  defp deliver(state), do: state

  defp take(events, event) do
    case Enum.split_while(events, &(&1["event"] != event)) do
      {_before, []} -> {nil, events}
      {before, [found | rest]} -> {found, before ++ rest}
    end
  end

  # Reassembles lines from arbitrary chunk boundaries. A trailing partial line is
  # kept in the buffer rather than parsed — the client flushes per line, but the
  # OS is under no obligation to deliver them one at a time.
  defp split_lines(data) do
    case String.split(data, "\n") do
      [only] -> {[], only}
      parts -> {parts |> Enum.drop(-1) |> Enum.reject(&(&1 == "")), List.last(parts)}
    end
  end
end
