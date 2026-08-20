defmodule Skulkd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # One room per GenServer, addressed by room id. The registry is what makes
        # room creation atomic (spec §21) — see Skulkd.Rooms.
        {Registry, keys: :unique, name: Skulkd.RoomRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Skulkd.RoomSupervisor}
      ] ++ server()

    opts = [strategy: :one_for_one, name: Skulkd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tests start their own Bandit on an ephemeral port, so the application must not
  # claim a fixed one out from under them. config/test.exs sets server: false.
  defp server do
    if Application.get_env(:skulkd, :server, true) do
      [{Bandit, plug: Skulkd.Router, port: Application.get_env(:skulkd, :port, 4000)}]
    else
      []
    end
  end
end
