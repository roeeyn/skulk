defmodule Skulkd.WSClient do
  @moduledoc """
  A deliberately raw WebSocket client for transport tests.

  Raw is the requirement, not a shortcut: the golden corpus contains frames no
  well-behaved client would ever send — truncated JSON, a binary frame carrying a
  valid `ping`, a frame one byte past the limit. A convenience wrapper that
  serialized structs could not express any of them.

  Built on `mint_web_socket`, test-only.
  """

  defstruct [:conn, :websocket, :ref, pending: []]

  @doc "Connects to `/v1/ws` on a running relay and completes the upgrade."
  def connect(port, path \\ "/v1/ws") do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])

    {:ok, conn, upgrade} = await_upgrade(conn, ref)
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, upgrade.status, upgrade.headers)

    {:ok, %__MODULE__{conn: conn, websocket: websocket, ref: ref}}
  end

  @doc "Sends a frame map as JSON in a text frame."
  def send_frame(client, frame) when is_map(frame),
    do: send_raw(client, {:text, Jason.encode!(frame)})

  @doc """
  Sends whatever bytes you give it, as whatever opcode you name.

  This is the entry point the corpus needs: `{:text, "{\\"v\\":0,"}` for truncated
  JSON, `{:binary, valid_json}` for the binary-frame vector.
  """
  def send_raw(client, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(client.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    {:ok, %{client | conn: conn, websocket: websocket}}
  end

  @doc """
  Receives the next decoded frame, or `{:error, :closed}` when the relay hung up.

  Returns `{:ok, client, frame}` where `frame` is a decoded JSON map for text
  frames, or `{:close, code, reason}` for a close frame — transport tests assert on
  both, since "sends an error frame AND closes" is two observable things.
  """
  def recv(client, timeout \\ 1_000) do
    case next_frame(client, timeout) do
      {:ok, client, {:text, body}} -> {:ok, client, Jason.decode!(body)}
      {:ok, client, {:close, code, reason}} -> {:ok, client, {:close, code, reason}}
      {:ok, client, other} -> {:ok, client, other}
      other -> other
    end
  end

  @doc "Asserts the relay closed the connection, returning the close frame if it sent one."
  def recv_close(client, timeout \\ 1_000) do
    case recv(client, timeout) do
      {:ok, _client, {:close, code, reason}} -> {:closed, code, reason}
      {:error, :closed} -> {:closed, nil, nil}
      other -> other
    end
  end

  # A 101 upgrade yields :status and :headers and no :done, so completion is "we
  # have both" rather than "the response finished."
  defp await_upgrade(conn, ref, acc \\ %{}) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            acc =
              Enum.reduce(responses, acc, fn
                {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
                {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
                _other, acc -> acc
              end)

            if Map.has_key?(acc, :status) and Map.has_key?(acc, :headers) do
              {:ok, conn, acc}
            else
              await_upgrade(conn, ref, acc)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}
        end
    after
      5_000 -> {:error, :upgrade_timeout}
    end
  end

  # Two things here are easy to get wrong and both bite in multi-client tests.
  #
  # The receive pattern matches THIS connection's socket only. Several clients share
  # one test process mailbox, so a naive `receive do message ->` happily consumes a
  # sibling's TCP packet, hands it to the wrong Mint connection, and gets :unknown
  # back — which looks exactly like a closed socket. It is not.
  #
  # And one TCP packet can carry several WebSocket frames (a join.ok immediately
  # followed by a chat.message, say), so leftovers are buffered rather than dropped.
  defp next_frame(%{pending: [frame | rest]} = client, _timeout) do
    {:ok, %{client | pending: rest}, frame}
  end

  defp next_frame(client, timeout) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      {tag, ^socket, _data} = message when tag in [:tcp, :ssl] ->
        handle(client, message, timeout)

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        handle(client, message, timeout)

      {tag, ^socket, _reason} = message when tag in [:tcp_error, :ssl_error] ->
        handle(client, message, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  defp handle(client, message, timeout) do
    case Mint.WebSocket.stream(client.conn, message) do
      {:ok, conn, responses} ->
        client = %{client | conn: conn}

        data =
          responses
          |> Enum.filter(&match?({:data, _ref, _data}, &1))
          |> Enum.map_join(&elem(&1, 2))

        if data == "" do
          if Enum.any?(responses, &match?({:done, _}, &1)),
            do: {:error, :closed},
            else: next_frame(client, timeout)
        else
          {:ok, websocket, frames} = Mint.WebSocket.decode(client.websocket, data)
          client = %{client | websocket: websocket}

          case frames ++ client.pending do
            [frame | rest] -> {:ok, %{client | pending: rest}, frame}
            [] -> next_frame(client, timeout)
          end
        end

      {:error, _conn, _reason, _responses} ->
        {:error, :closed}

      :unknown ->
        {:error, :closed}
    end
  end
end
