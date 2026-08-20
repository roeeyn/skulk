defmodule Skulkd.Router do
  @moduledoc """
  The relay's entire HTTP surface: a health endpoint and a WebSocket upgrade.

  Plug and Bandit directly, no Phoenix — design A13. Phoenix Channels would impose a
  second wire protocol on top of protocol v0 and drag weakly-maintained Phoenix
  client libraries into the Go side.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # Spec §16.1: service health and protocol version, and nothing else. No build
  # metadata, no room counts, no uptime — an unauthenticated endpoint is not a place
  # to publish operational detail about an unlisted-rooms service.
  get "/healthz" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"status" => "ok", "protocol_version" => 0}))
  end

  get "/v1/ws" do
    conn
    |> WebSockAdapter.upgrade(Skulkd.Conn, [], timeout: :timer.minutes(10))
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
