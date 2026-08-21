defmodule Skulkd.ProtocolOracle do
  @moduledoc """
  The Go validator, asked one frame at a time.

  Design A13 gives skulk two independent protocol codecs, and `docs/protocol/corpus/`
  checks they agree on the vectors somebody thought of. This is how ROJ-44 checks
  they agree on the ones nobody did: a long-lived `cmd/protocol-oracle` process on
  a Port, so a property test can put hundreds of thousands of generated frames
  through *both* implementations and compare verdicts.

  One process for the whole suite (`setup_all`), because the alternative — a
  process per frame — spends milliseconds of fork on a microsecond of validation.

  ## Crashes are findings, not infrastructure failures

  "No input crashes either validator" is one of the properties under test, so this
  module keeps the frame it is waiting on. If the oracle dies, the caller is told
  which base64 killed it rather than being handed a bare port error — the whole
  value of the finding is the input that produced it.
  """

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct [:port, :caller, :in_flight]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc """
  The verdict the Go validator returns for `frame`.

  `:ok`, or the §6 error code as a string. `{:crash, detail}` if the oracle died on
  this input, and `{:timeout, detail}` if it stopped answering — both of which are
  test failures with the offending frame attached rather than exceptions.
  """
  @spec verdict(GenServer.server(), :relay | :client, :text | :binary, binary()) ::
          :ok | String.t() | {:crash, String.t()} | {:timeout, String.t()}
  def verdict(oracle, receiver, kind, frame, timeout \\ 5_000) do
    GenServer.call(oracle, {:verdict, receiver, kind, frame, timeout}, timeout + 1_000)
  end

  # --------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    binary = System.get_env("SKULK_ORACLE_BIN") || raise "SKULK_ORACLE_BIN is not set"

    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :hide,
        {:line, 4_194_304}
      ])

    {:ok, %State{port: port}}
  end

  @impl true
  def handle_call({:verdict, receiver, kind, frame, timeout}, from, state) do
    encoded = Base.encode64(frame)
    Port.command(state.port, "#{receiver} #{kind} #{encoded}\n")

    timer = Process.send_after(self(), {:no_answer, from}, timeout)
    {:noreply, %{state | caller: {from, timer}, in_flight: encoded}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %State{port: port} = state) do
    {:noreply, answer(state, decode(line))}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    # The oracle died on the frame it was holding. That IS the finding.
    detail = "the Go validator exited #{status} on base64 #{state.in_flight}"
    {:stop, :normal, answer(state, {:crash, detail})}
  end

  def handle_info({:no_answer, from}, %State{caller: {from, _}} = state) do
    {:noreply, answer(state, {:timeout, "no verdict for base64 #{state.in_flight}"})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --------------------------------------------------------------------------

  defp decode("ok"), do: :ok
  defp decode(code), do: code

  defp answer(%State{caller: nil} = state, _reply), do: state

  defp answer(%State{caller: {from, timer}} = state, reply) do
    Process.cancel_timer(timer)
    GenServer.reply(from, reply)
    %{state | caller: nil}
  end
end
