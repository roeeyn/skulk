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
        # Ahead of the rooms: every room registers with the capacity counter as it
        # starts (spec §8's global retained-history bound), so the counter has to
        # already be there.
        Skulkd.Capacity,
        {DynamicSupervisor, strategy: :one_for_one, name: Skulkd.RoomSupervisor}
      ] ++ server()

    opts = [strategy: :one_for_one, name: Skulkd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tests start their own Bandit on an ephemeral port, so the application must not
  # claim a fixed one out from under them. config/test.exs sets server: false.
  defp server do
    if Application.get_env(:skulkd, :server, true) do
      [{Bandit, [plug: Skulkd.Router, port: Application.get_env(:skulkd, :port, 4000)] ++ ip()}]
    else
      []
    end
  end

  # Bandit binds every interface unless told otherwise, which is what a container
  # wants. `SKULKD_BIND=127.0.0.1:4000` is what a relay behind a TLS reverse proxy
  # wants — see Skulkd.Config. Absent rather than defaulted here, so Bandit's own
  # default stays the one documented.
  defp ip do
    case Application.fetch_env(:skulkd, :ip) do
      {:ok, ip} -> [ip: ip]
      :error -> []
    end
  end
end
