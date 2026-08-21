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
    |> WebSockAdapter.upgrade(Skulkd.Conn, [], timeout: idle_timeout())
    |> halt()
  end

  # Bandit's WebSocket IDLE timeout: how long a connection may go without the client
  # sending anything before Bandit closes it — with code 1002, which reads like a
  # protocol error but means "you went quiet" (bandit/websocket/connection.ex,
  # handle_timeout/2).
  #
  # Ten minutes of not typing is ordinary, so the client answers this with protocol
  # v0 §5.10 pings rather than the bound being made enormous. This stays as the
  # backstop it is meant to be: a peer that has genuinely gone away is hung up on.
  # Configurable so tests can pin the behaviour without waiting ten minutes.
  defp idle_timeout do
    Application.get_env(:skulkd, :websocket_idle_timeout, :timer.minutes(10))
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
