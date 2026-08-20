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

  defp presence(sender_id, username, participant_count) do
    %{"sender_id" => sender_id, "username" => username, "participant_count" => participant_count}
  end
end
