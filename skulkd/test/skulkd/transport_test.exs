defmodule Skulkd.TransportTest do
  @moduledoc """
  ROJ-32 (M0-4) acceptance criteria, over a real socket.

  Every test boots its own Bandit on an ephemeral port and drives it with
  `Skulkd.WSClient`, a deliberately raw WebSocket client — raw because the golden
  corpus contains frames no well-behaved client would ever send.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Skulkd.Fixtures
  alias Skulkd.ProtocolCorpus, as: Corpus
  alias Skulkd.WSClient

  setup do
    pid = start_supervised!({Bandit, plug: Skulkd.Router, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{port: port}
  end

  defp open(port) do
    {:ok, client} = WSClient.connect(port)
    client
  end

  defp send_recv(client, frame) do
    {:ok, client} = WSClient.send_frame(client, frame)
    {:ok, client, response} = WSClient.recv(client)
    {client, response}
  end

  defp envelope(type, payload, request_id \\ nil) do
    frame = %{"v" => 0, "type" => type, "payload" => payload}
    if request_id, do: Map.put(frame, "request_id", request_id), else: frame
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
  end

  # ---------------------------------------------------------------------------
  describe "AC1 · GET /healthz" do
    test "returns 200 with service status and protocol version, and nothing else", %{port: port} do
      {status, headers, body} = http_get(port, "/healthz")

      assert status == 200
      assert {_, "application/json; charset=utf-8"} = List.keyfind(headers, "content-type", 0)

      # "Nothing else" is the assertion that matters: an unauthenticated endpoint on
      # an unlisted-rooms service must not publish build metadata, room counts, or
      # uptime. Asserting the exact key set is what keeps that true over time.
      assert Jason.decode!(body) == %{"status" => "ok", "protocol_version" => 0}
    end

    test "an unknown path is a plain 404", %{port: port} do
      assert {404, _headers, _body} = http_get(port, "/rooms")
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC2 · the happy path over a real socket" do
    test "create, join with snapshot, and a message both connections see", %{port: port} do
      room_id = Fixtures.room_id()
      password = Fixtures.password()

      # create.begin -> create.ok
      alice = open(port)
      create_id = uuid()

      {alice, response} =
        send_recv(
          alice,
          envelope("create.begin", %{"room_id" => room_id, "password" => password}, create_id)
        )

      assert response["type"] == "create.ok"
      assert response["request_id"] == create_id
      assert response["payload"]["room_id"] == room_id
      assert response["payload"]["username"] =~ ~r/^[a-z]+-[a-z]+-[0-9]{2}$/
      refute Map.has_key?(response["payload"], "history"), "create.ok carries no history (D8)"

      # A message before anyone joins, so the joiner's snapshot is non-empty.
      {alice, first} =
        send_recv(
          alice,
          envelope("chat.send", %{"message_id" => uuid(), "text" => "before you arrived"})
        )

      assert first["type"] == "chat.message"
      assert first["payload"]["sequence"] == 1

      # join.begin -> join.ok, carrying the snapshot inline (D11)
      bob = open(port)
      join_id = uuid()

      {bob, response} =
        send_recv(
          bob,
          envelope("join.begin", %{"room_id" => room_id, "password" => password}, join_id)
        )

      assert response["type"] == "join.ok"
      assert response["request_id"] == join_id
      assert Enum.map(response["payload"]["history"], & &1["text"]) == ["before you arrived"]
      assert response["payload"]["snapshot_sequence"] == 1
      assert length(response["payload"]["participants"]) == 2

      # alice learns about bob
      {:ok, alice, presence} = WSClient.recv(alice)
      assert presence["type"] == "presence.joined"
      assert presence["payload"]["participant_count"] == 2

      # chat.send -> both connections receive the identical chat.message (A11)
      {bob, bobs_copy} =
        send_recv(bob, envelope("chat.send", %{"message_id" => uuid(), "text" => "hello alice"}))

      {:ok, _alice, alices_copy} = WSClient.recv(alice)

      assert bobs_copy["type"] == "chat.message"
      assert bobs_copy["payload"]["sequence"] == 2
      # Byte-identical, sender included: at M4 any difference reads as tampering.
      assert bobs_copy == alices_copy

      # presence.list is the wire form of /who
      who_id = uuid()
      {_bob, roster} = send_recv(bob, envelope("presence.list", %{}, who_id))
      assert roster["type"] == "presence.list"
      assert roster["request_id"] == who_id
      assert roster["payload"]["participant_count"] == 2
    end

    test "a wrong password is authentication_failed and the socket stays open", %{port: port} do
      room_id = Fixtures.room_id()
      alice = open(port)

      {_alice, _} =
        send_recv(
          alice,
          envelope(
            "create.begin",
            %{"room_id" => room_id, "password" => Fixtures.password()},
            uuid()
          )
        )

      bob = open(port)
      request_id = uuid()

      {bob, response} =
        send_recv(
          bob,
          envelope(
            "join.begin",
            %{"room_id" => room_id, "password" => "wrong-password-entirely"},
            request_id
          )
        )

      assert response["type"] == "error"
      assert response["payload"]["code"] == "authentication_failed"
      assert response["request_id"] == request_id

      # Still usable: a bad credential is a recoverable mistake, not a hang-up.
      {_bob, pong} = send_recv(bob, envelope("ping", %{}, uuid()))
      assert pong["type"] == "pong"
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC3 · binary frames (spec §16.1)" do
    test "are rejected with unsupported_frame_type and the connection closes", %{port: port} do
      client = open(port)

      # The bytes are a perfectly valid ping. The frame KIND alone disqualifies it —
      # rule V1 runs before anything is parsed.
      valid_ping = Jason.encode!(envelope("ping", %{}, uuid()))
      {:ok, client} = WSClient.send_raw(client, {:binary, valid_ping})

      {:ok, client, response} = WSClient.recv(client)
      assert response["type"] == "error"
      assert response["payload"]["code"] == "unsupported_frame_type"

      assert {:closed, _code, _reason} = WSClient.recv_close(client)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC4 · malformed envelopes" do
    test "malformed JSON is invalid_message and closes", %{port: port} do
      client = open(port)
      {:ok, client} = WSClient.send_raw(client, {:text, ~s({"v":0,"type":"ping","payload":{)})

      {:ok, client, response} = WSClient.recv(client)
      assert response["payload"]["code"] == "invalid_message"
      assert {:closed, _, _} = WSClient.recv_close(client)
    end

    test "a missing v is invalid_message, not a version complaint", %{port: port} do
      client = open(port)
      {:ok, client} = WSClient.send_raw(client, {:text, ~s({"type":"ping","payload":{}})})

      {:ok, _client, response} = WSClient.recv(client)
      assert response["payload"]["code"] == "invalid_message"
    end

    test "an unknown v is unsupported_protocol_version and closes", %{port: port} do
      client = open(port)
      {:ok, client} = WSClient.send_frame(client, %{"v" => 1, "type" => "ping", "payload" => %{}})

      {:ok, client, response} = WSClient.recv(client)
      assert response["payload"]["code"] == "unsupported_protocol_version"
      assert {:closed, _, _} = WSClient.recv_close(client)
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC5 · every client-sent invalid corpus vector, over the socket" do
    # Only c2r vectors: an r2c vector sent TO the relay is a direction violation, so
    # it would produce invalid_message rather than the code annotated for a client
    # receiving it. The unit-level corpus walk in protocol_contract_test.exs covers
    # both roles; this asserts the codes survive the transport.
    for vector <- Enum.filter(Corpus.invalid(), &(&1["receiver"] == "relay")) do
      @vector vector

      test vector["name"], %{port: port} do
        vector = @vector
        {:ok, bytes} = Corpus.frame_bytes(vector)
        kind = Corpus.kind(vector)

        client = open(port)
        {:ok, client} = WSClient.send_raw(client, {kind, bytes})

        if kind == :text and not String.valid?(bytes) do
          # Transport-shadowed, and legitimately so: the WebSocket protocol requires
          # text frames to be valid UTF-8, so Bandit rejects this one before it can
          # reach the application. That is a STRONGER rejection than our V3, not a
          # gap — the frame never becomes a frame. The unit corpus walk still pins
          # the invalid_message code for the codec itself.
          assert {:closed, _code, _reason} = WSClient.recv_close(client)
        else
          {:ok, client, response} = WSClient.recv(client)

          assert response["type"] == "error",
                 "expected an error frame, got #{inspect(response)}\n  #{vector["path"]}"

          assert response["payload"]["code"] == vector["expect"]["error_code"],
                 """
                 wrong error code over the socket (rule #{vector["expect"]["rule"]})
                   #{vector["description"]}
                   #{vector["path"]}
                 """

          if vector["expect"]["close"] do
            assert {:closed, _, _} = WSClient.recv_close(client)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC6 · unknown frame types" do
    test "are rejected without killing the connection", %{port: port} do
      client = open(port)

      {client, response} = send_recv(client, envelope("chat.whisper", %{"text" => "hi"}, uuid()))
      assert response["payload"]["code"] == "unsupported_frame_type"

      # The Conn survived: §7.1 keeps recoverable per-frame mistakes non-fatal so an
      # agent that mistypes one frame gets a diagnosis rather than a hang-up (A15).
      {_client, pong} = send_recv(client, envelope("ping", %{}, uuid()))
      assert pong["type"] == "pong"
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC7 · abrupt disconnect" do
    test "the remaining member sees presence.left within a second", %{port: port} do
      room_id = Fixtures.room_id()
      password = Fixtures.password()

      alice = open(port)

      {alice, _} =
        send_recv(
          alice,
          envelope("create.begin", %{"room_id" => room_id, "password" => password}, uuid())
        )

      bob = open(port)

      {bob, joined} =
        send_recv(
          bob,
          envelope("join.begin", %{"room_id" => room_id, "password" => password}, uuid())
        )

      bob_sender_id = joined["payload"]["sender_id"]

      {:ok, alice, presence} = WSClient.recv(alice)
      assert presence["type"] == "presence.joined"

      # No close frame, no goodbye — the socket just dies. The Conn process is the
      # member Room monitors, so this arrives as a :DOWN with no cleanup code of ours.
      Mint.HTTP.close(bob.conn)

      {:ok, _alice, left} = WSClient.recv(alice, 1_000)
      assert left["type"] == "presence.left"
      assert left["payload"]["sender_id"] == bob_sender_id
      assert left["payload"]["participant_count"] == 1
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC8 · frame size (spec §8, decision D2)" do
    test "a frame past 16 KiB is message_too_large", %{port: port} do
      client = open(port)

      # Padding lives in an unknown payload field, which §3 requires be ignored — so
      # size is the only rule that can fire.
      oversized =
        envelope(
          "chat.send",
          %{"message_id" => uuid(), "text" => "hi", "pad" => String.duplicate("p", 17_000)},
          uuid()
        )

      {:ok, client} = WSClient.send_frame(client, oversized)

      {:ok, client, response} = WSClient.recv(client)
      assert response["payload"]["code"] == "message_too_large"
      assert {:closed, _, _} = WSClient.recv_close(client)
    end

    test "text past 4096 bytes is message_too_large but does NOT close", %{port: port} do
      room_id = Fixtures.room_id()
      client = open(port)

      {client, _} =
        send_recv(
          client,
          envelope(
            "create.begin",
            %{"room_id" => room_id, "password" => Fixtures.password()},
            uuid()
          )
        )

      {client, response} =
        send_recv(
          client,
          envelope(
            "chat.send",
            %{"message_id" => uuid(), "text" => String.duplicate("a", 4097)},
            uuid()
          )
        )

      assert response["payload"]["code"] == "message_too_large"

      # Same code, different rule, different consequence: V2 closes, V13 does not.
      {_client, pong} = send_recv(client, envelope("ping", %{}, uuid()))
      assert pong["type"] == "pong"
    end
  end

  # ---------------------------------------------------------------------------
  describe "AC9 · logging (spec §18.1)" do
    test "no frame contents reach the log", %{port: port} do
      password = "unmistakable-transport-pw-3c9f"
      text = "unmistakable-transport-body-77ab"
      room_id = Fixtures.room_id()

      log =
        capture_log(fn ->
          client = open(port)

          {client, _} =
            send_recv(
              client,
              envelope("create.begin", %{"room_id" => room_id, "password" => password}, uuid())
            )

          {client, _} =
            send_recv(client, envelope("chat.send", %{"message_id" => uuid(), "text" => text}))

          # A rejected frame is the likelier place for contents to leak into a log.
          {_client, _} =
            send_recv(
              client,
              envelope("chat.send", %{"message_id" => "not-a-uuid", "text" => text})
            )
        end)

      # Prove the refutes are not vacuous. Test env runs Logger at :debug, so the
      # rejection path's line IS captured — which is the point: that path handles a
      # frame someone got wrong, making it the likeliest place for contents to leak
      # into a log, and it must log the code and nothing else.
      assert log =~ "rejecting frame: invalid_message"

      refute log =~ password
      refute log =~ text
      refute log =~ room_id
    end
  end

  # ---------------------------------------------------------------------------

  # Why Mint here rather than Req, which would make this two lines:
  #
  # mint_web_socket is not optional — Req is built on Finch, and Finch is HTTP-only,
  # so nothing in that stack can perform a WebSocket upgrade. Since Mint is already
  # in the test env for that reason, this one HTTP request reuses it rather than
  # pulling a second HTTP client (and finch, nimble_options, nimble_pool, castore)
  # in for a single GET. The plumbing below is the price of that choice; it is
  # confined to this helper.
  defp http_get(port, path) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, [], nil)
    collect(conn, ref, [])
  end

  defp collect(conn, ref, acc) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.HTTP.stream(conn, message)
        acc = acc ++ responses

        if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
          status =
            Enum.find_value(acc, fn
              {:status, _, s} -> s
              _ -> nil
            end)

          headers =
            Enum.find_value(acc, fn
              {:headers, _, h} -> h
              _ -> nil
            end)

          body = acc |> Enum.filter(&match?({:data, _, _}, &1)) |> Enum.map_join(&elem(&1, 2))
          {status, headers, body}
        else
          collect(conn, ref, acc)
        end
    after
      2_000 -> flunk("timed out waiting for #{inspect(ref)}")
    end
  end
end
