defmodule Skulkd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # One room per GenServer, addressed by room id. The registry is what makes
      # room creation atomic (spec §21) — see Skulkd.Rooms.
      {Registry, keys: :unique, name: Skulkd.RoomRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Skulkd.RoomSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Skulkd.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
