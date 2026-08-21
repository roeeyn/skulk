defmodule Skulkd.Frames do
  @moduledoc """
  Builds the protocol v0 relay→client frames a room broadcasts
  (docs/protocol-v0.md §5).

  Build only — validation is `Skulkd.Protocol` (ROJ-32). Frames are string-keyed
  because that is what a decoded JSON frame looks like on the other side of the
  socket; building them any other way would mean converting at the transport
  boundary and again in every test assertion.
  """

  @version 0

  @doc "An unsolicited relay→client frame. Broadcasts carry no `request_id` (§4.3)."
  @spec push(String.t(), map()) :: map()
  def push(type, payload) when is_binary(type) and is_map(payload) do
    %{"v" => @version, "type" => type, "payload" => payload}
  end

  @doc """
  A `chat.message` frame (§5.6).

  The identical frame goes to every member **including the sender** (amendment
  A11): at M4 the sender folds its own messages using the relay-assigned `sequence`
  it can only learn from this echo, and A1d's self-suppression check is exactly
  "did my own message come back to me."
  """
  def chat_message(payload), do: push("chat.message", payload)

  def presence_joined(sender_id, username, participant_count) do
    push("presence.joined", presence(sender_id, username, participant_count))
  end

  def presence_left(sender_id, username, participant_count) do
    push("presence.left", presence(sender_id, username, participant_count))
  end

  def room_expired(room_id, expired_at) do
    push("room.expired", %{"room_id" => room_id, "expired_at" => expired_at})
  end

  @doc """
  A relay→client response to a specific request, echoing its `request_id` verbatim
  (§4.3). Distinct from `push/2`: broadcasts carry no correlation id, replies must.
  """
  @spec reply(String.t(), String.t() | nil, map()) :: map()
  def reply(type, request_id, payload) do
    frame = push(type, payload)
    if request_id, do: Map.put(frame, "request_id", request_id), else: frame
  end

  @doc "`create.ok` (§5.2) — a new room has no history, so no snapshot fields (D8)."
  def create_ok(request_id, session) do
    reply("create.ok", request_id, %{
      "room_id" => session.room_id,
      "sender_id" => session.sender_id,
      "username" => session.username,
      "expires_at" => session.expires_at,
      "participants" => session.participants
    })
  end

  @doc "`join.ok` (§5.4) — carries the history snapshot and its boundary inline (D11)."
  def join_ok(request_id, session) do
    reply("join.ok", request_id, %{
      "room_id" => session.room_id,
      "sender_id" => session.sender_id,
      "username" => session.username,
      "expires_at" => session.expires_at,
      "participants" => session.participants,
      "history" => session.history,
      "snapshot_sequence" => session.snapshot_sequence
    })
  end

  @doc "The `/who` response (§5.8). `participant_count` must equal `length(participants)`."
  def presence_list(request_id, participants) do
    reply("presence.list", request_id, %{
      "participants" => participants,
      "participant_count" => length(participants)
    })
  end

  @doc "`pong` (§5.10), echoing the ping's `request_id` — the only correlation available."
  def pong(request_id), do: reply("pong", request_id, %{})

  @doc """
  An `error` frame (§5.11).

  The message is human-readable and carries no machine meaning — clients branch on
  `code` alone. It MUST NOT contain stack traces, secret material, password lengths,
  or message text (spec §17, §18), which is why it is derived from the code here
  rather than passed in from a call site that might have a password in scope.
  """
  def error(code, request_id \\ nil) do
    reply("error", request_id, %{"code" => wire_code(code), "message" => message(code)})
  end

  # §6 registers exactly eleven codes and BOTH codecs enum-validate the field, so a
  # frame carrying anything else is one this relay's own validator would reject.
  # Internal failure reasons do reach here — `no_username_available` from an
  # exhausted namespace is the reachable-in-principle example — and the honest
  # thing to tell a client about a reason it has no vocabulary for is
  # `internal_error`.
  defp wire_code(code) do
    code = to_string(code)
    if code in Skulkd.Protocol.error_codes(), do: code, else: "internal_error"
  end

  defp message(:room_not_found), do: "room not found"
  defp message(:room_already_exists), do: "room already exists"
  defp message(:authentication_failed), do: "authentication failed"
  defp message(:room_expired), do: "room expired"
  defp message(:room_full), do: "room is full"
  # Deliberately says nothing about WHICH limit was hit: §8 and spec §17/§18 keep
  # capacity numbers out of a frame any unauthenticated caller can provoke.
  defp message(:server_capacity), do: "at capacity"
  defp message(:message_too_large), do: "message too large"
  defp message(:invalid_message), do: "invalid message"
  defp message(:unsupported_protocol_version), do: "unsupported protocol version"
  defp message(:unsupported_frame_type), do: "unsupported frame type"
  defp message(_), do: "internal error"

  defp presence(sender_id, username, participant_count) do
    %{"sender_id" => sender_id, "username" => username, "participant_count" => participant_count}
  end
end
