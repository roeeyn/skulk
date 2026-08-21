defmodule Skulkd.Protocol do
  @moduledoc """
  Protocol v0 frame validation — the relay half of the cross-language contract.

  `docs/protocol-v0.md` is normative and `docs/protocol/corpus/` is its executable
  form: this module and the Go client's `internal/protocol` must accept the same
  frames and reject the others **with the same error code**. Where this module and
  the corpus disagree, the corpus is right until the document says otherwise.

  Two things about the shape of this code are deliberate:

  **The rules run in a fixed order (§7) and stop at the first failure.** A malformed
  frame usually breaks several rules at once, so without a defined order Go and
  Elixir could both be "correct" and still disagree about the code. Every function
  below is one rule, chained, in the order the document gives.

  **The registry is data, not code paths.** One `@frames` map keyed by
  `{type, direction}` drives V8 through V13, so adding a frame type is a data edit
  rather than a new branch in five functions.
  """

  @version 0

  # docs/protocol-v0.md §2.1 / §4.
  @max_relay_frame_bytes 16_384
  @max_text_bytes 4_096
  @min_password_bytes 12
  @max_password_bytes 256
  @max_room_id_bytes 160
  @max_username_bytes 64
  @max_error_message_bytes 256
  @max_sequence 9_007_199_254_740_991

  @room_id ~r/^[a-z]+(-[a-z]+){7}$/
  @username ~r/^[a-z]+-[a-z]+-[0-9]{2}$/
  @sender_id ~r/^[A-Za-z0-9_-]{22}$/
  @uuid4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @timestamp ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/

  # §6. Exactly eleven since M1 (ROJ-39) made `server_capacity` reachable. §17
  # groups it with `room_full` on exit code 6.
  @error_codes ~w(
    room_not_found room_already_exists authentication_failed room_expired room_full
    server_capacity message_too_large invalid_message unsupported_protocol_version
    unsupported_frame_type internal_error
  )

  @participant [{"sender_id", :string, :sender_id}, {"username", :string, :username}]

  @presence [
    {"sender_id", :string, :sender_id},
    {"username", :string, :username},
    {"participant_count", :integer, :count}
  ]

  @chat_message_fields [
    {"room_id", :string, :room_id},
    {"message_id", :string, :uuid4},
    {"sender_id", :string, :sender_id},
    {"sender_username", :string, :username},
    {"sequence", :integer, :sequence},
    {"received_at", :string, :timestamp},
    {"text", :string, :text}
  ]

  # §5, as data. Keyed by {type, direction} because presence.list carries a different
  # payload in each direction (decision D7).
  @frames %{
    {"create.begin", :c2r} => %{
      request_id: :required,
      fields: [{"room_id", :string, :room_id}, {"password", :string, :password}]
    },
    {"create.ok", :r2c} => %{
      request_id: :required,
      fields: [
        {"room_id", :string, :room_id},
        {"sender_id", :string, :sender_id},
        {"username", :string, :username},
        {"expires_at", :string, :timestamp},
        {"participants", :array, :participants}
      ]
    },
    {"join.begin", :c2r} => %{
      request_id: :required,
      fields: [{"room_id", :string, :room_id}, {"password", :string, :password}]
    },
    {"join.ok", :r2c} => %{
      request_id: :required,
      fields: [
        {"room_id", :string, :room_id},
        {"sender_id", :string, :sender_id},
        {"username", :string, :username},
        {"expires_at", :string, :timestamp},
        {"participants", :array, :participants},
        {"history", :array, :history},
        {"snapshot_sequence", :integer, :snapshot_sequence}
      ]
    },
    {"chat.send", :c2r} => %{
      request_id: :optional,
      fields: [{"message_id", :string, :uuid4}, {"text", :string, :text}]
    },
    {"chat.message", :r2c} => %{request_id: :absent, fields: @chat_message_fields},
    {"presence.joined", :r2c} => %{request_id: :absent, fields: @presence},
    {"presence.left", :r2c} => %{request_id: :absent, fields: @presence},
    {"presence.list", :c2r} => %{request_id: :required, fields: []},
    {"presence.list", :r2c} => %{
      request_id: :required,
      fields: [
        {"participants", :array, :participants},
        {"participant_count", :integer, :count}
      ]
    },
    {"room.expired", :r2c} => %{
      request_id: :absent,
      fields: [{"room_id", :string, :room_id}, {"expired_at", :string, :timestamp}]
    },
    {"ping", :c2r} => %{request_id: :required, fields: []},
    {"ping", :r2c} => %{request_id: :required, fields: []},
    {"pong", :c2r} => %{request_id: :required, fields: []},
    {"pong", :r2c} => %{request_id: :required, fields: []},
    {"error", :r2c} => %{
      request_id: :optional,
      fields: [{"code", :string, :error_code}, {"message", :string, :error_message}]
    }
  }

  @known_types @frames |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> MapSet.new()

  @type role :: :relay | :client
  @type kind :: :text | :binary
  @type code :: atom()

  @doc """
  Validates one received frame as `receiver`, returning `:ok` or the protocol v0
  error code the receiver must answer with.

  This is the corpus contract seam (`docs/protocol/corpus/README.md`). Transport
  wants `decode/3` instead, which also hands back the parsed frame and says whether
  to close the connection.
  """
  @spec validate(role(), kind(), binary()) :: :ok | {:error, code()}
  def validate(receiver, kind, frame) do
    case decode(receiver, kind, frame) do
      {:ok, _} -> :ok
      {:error, code, _close?} -> {:error, code}
    end
  end

  @doc """
  Validates and parses one received frame.

  Returns `{:error, code, close?}` on rejection. `close?` is a property of the RULE,
  not the code: `message_too_large` closes when the whole frame was oversized (V2,
  the peer is not speaking this protocol) but not when only `text` was (V13, one bad
  message). §7.1 has the reasoning — recoverable per-frame mistakes get a diagnosis,
  not a hang-up, because an AI agent that mistypes one frame should be able to
  continue (A15).
  """
  @spec decode(role(), kind(), binary()) :: {:ok, map()} | {:error, code(), boolean()}
  def decode(receiver, kind, frame) do
    direction = direction(receiver)

    with :ok <- v1_text_frame(kind),
         :ok <- v2_frame_size(receiver, frame),
         :ok <- v3_utf8(frame),
         {:ok, decoded} <- v4_json_object(frame),
         :ok <- v5_version_present(decoded),
         :ok <- v6_version_supported(decoded),
         {:ok, type} <- v7_type_present(decoded),
         :ok <- v8_type_known(type),
         :ok <- v9_request_id(decoded, type, direction),
         {:ok, payload} <- v10_payload_object(decoded),
         {:ok, spec} <- v11_direction(type, direction),
         :ok <- v12_payload_fields(payload, spec),
         :ok <- v13_payload_values(payload, spec) do
      {:ok, decoded}
    end
  end

  @doc "The direction a frame travelled, given who received it."
  @spec direction(role()) :: :c2r | :r2c
  def direction(:relay), do: :c2r
  def direction(:client), do: :r2c

  @doc "The ten protocol v0 error codes (§6)."
  def error_codes, do: @error_codes

  @doc """
  Whether a value is a usable `request_id`.

  Transport uses this before echoing a salvaged id back in an `error` frame: a
  malformed one would make our own reply fail V9 at the client.
  """
  @spec valid_request_id?(term()) :: boolean()
  def valid_request_id?(value) when is_binary(value), do: Regex.match?(@uuid4, value)
  def valid_request_id?(_), do: false

  @doc "The maximum frame the relay accepts (§2.1). Inbound only — decision D2."
  def max_relay_frame_bytes, do: @max_relay_frame_bytes

  # --------------------------------------------------------------------------
  # The rules, in order. Each returns :ok/{:ok, _} or {:error, code, close?}.
  # --------------------------------------------------------------------------

  defp v1_text_frame(:text), do: :ok
  defp v1_text_frame(:binary), do: {:error, :unsupported_frame_type, true}

  # Relay only (D2): spec §8's 16 KiB cap and §15's 4 MiB retained history cannot
  # both hold when join.ok carries an inline snapshot. The bound exists to stop a
  # client making the relay allocate, which is an inbound concern.
  defp v2_frame_size(:relay, frame) when byte_size(frame) > @max_relay_frame_bytes,
    do: {:error, :message_too_large, true}

  defp v2_frame_size(_receiver, _frame), do: :ok

  defp v3_utf8(frame) do
    if String.valid?(frame), do: :ok, else: {:error, :invalid_message, true}
  end

  defp v4_json_object(frame) do
    case Jason.decode(frame) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_message, true}
    end
  end

  # is_integer, not is_number: JSON `0.0` decodes to a float and is not the integer
  # this field is specified as.
  defp v5_version_present(%{"v" => v}) when is_integer(v), do: :ok
  defp v5_version_present(_), do: {:error, :invalid_message, true}

  defp v6_version_supported(%{"v" => @version}), do: :ok
  defp v6_version_supported(_), do: {:error, :unsupported_protocol_version, true}

  defp v7_type_present(%{"type" => type}) when is_binary(type), do: {:ok, type}
  defp v7_type_present(_), do: {:error, :invalid_message, true}

  defp v8_type_known(type) do
    if MapSet.member?(@known_types, type), do: :ok, else: {:error, :unsupported_frame_type, false}
  end

  defp v9_request_id(decoded, type, direction) do
    present = Map.has_key?(decoded, "request_id")
    value = Map.get(decoded, "request_id")

    # A type sent in the wrong direction has no §4.3 row, so there is no presence
    # rule to apply — only the shape check. V11 is what rejects it, one rule later.
    rule =
      case Map.fetch(@frames, {type, direction}) do
        {:ok, spec} -> spec.request_id
        :error -> :optional
      end

    cond do
      present and not (is_binary(value) and Regex.match?(@uuid4, value)) ->
        {:error, :invalid_message, false}

      rule in [:required, :echo] and not present ->
        {:error, :invalid_message, false}

      rule == :absent and present ->
        {:error, :invalid_message, false}

      true ->
        :ok
    end
  end

  defp v10_payload_object(%{"payload" => payload}) when is_map(payload), do: {:ok, payload}
  defp v10_payload_object(_), do: {:error, :invalid_message, false}

  defp v11_direction(type, direction) do
    case Map.fetch(@frames, {type, direction}) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :invalid_message, true}
    end
  end

  # Presence and JSON type only. Unknown payload keys are IGNORED (§3, decision D3) —
  # that is how M1-M3 add fields without breaking v0 readers.
  defp v12_payload_fields(payload, spec) do
    Enum.reduce_while(spec.fields, :ok, fn {name, json_type, _check}, _acc ->
      case Map.fetch(payload, name) do
        {:ok, value} ->
          if json_type?(value, json_type),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_message, false}}

        :error ->
          {:halt, {:error, :invalid_message, false}}
      end
    end)
  end

  defp v13_payload_values(payload, spec) do
    with :ok <- check_fields(payload, spec.fields) do
      cross_field(payload)
    end
  end

  defp check_fields(payload, fields) do
    Enum.reduce_while(fields, :ok, fn {name, _json_type, check}, _acc ->
      case check_value(Map.fetch!(payload, name), check) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # §5's cross-field invariants. Each is skipped when the fields are absent, because
  # a payload without them failed V12 already or does not carry them at all.
  defp cross_field(payload) do
    with :ok <- participant_count_matches(payload) do
      snapshot_boundary_matches(payload)
    end
  end

  defp participant_count_matches(%{"participants" => list, "participant_count" => count})
       when length(list) != count,
       do: {:error, :invalid_message, false}

  defp participant_count_matches(_), do: :ok

  defp snapshot_boundary_matches(%{"history" => history, "snapshot_sequence" => boundary}) do
    expected = history |> List.last() |> last_sequence()
    if boundary == expected, do: :ok, else: {:error, :invalid_message, false}
  end

  defp snapshot_boundary_matches(_), do: :ok

  # Decision D9: 0 for an empty snapshot, never null or absent. Sequences start at 1,
  # so 0 is unambiguous.
  defp last_sequence(nil), do: 0
  defp last_sequence(%{"sequence" => sequence}), do: sequence
  defp last_sequence(_), do: 0

  # --------------------------------------------------------------------------
  # Value checks (V13)
  # --------------------------------------------------------------------------

  defp check_value(value, :room_id),
    do: pattern(value, @room_id, @max_room_id_bytes)

  defp check_value(value, :username),
    do: pattern(value, @username, @max_username_bytes)

  defp check_value(value, :sender_id), do: pattern(value, @sender_id)
  defp check_value(value, :uuid4), do: pattern(value, @uuid4)
  defp check_value(value, :timestamp), do: pattern(value, @timestamp)

  defp check_value(value, :password) do
    if byte_size(value) in @min_password_bytes..@max_password_bytes,
      do: :ok,
      else: invalid()
  end

  # The one V13 failure that is not invalid_message. Note the bound is BYTES: an
  # implementation counting characters accepts frames it must reject.
  defp check_value(value, :text) do
    cond do
      byte_size(value) > @max_text_bytes -> {:error, :message_too_large, false}
      byte_size(value) < 1 -> invalid()
      true -> :ok
    end
  end

  defp check_value(value, :sequence) do
    if value >= 1 and value <= @max_sequence, do: :ok, else: invalid()
  end

  defp check_value(value, :snapshot_sequence) do
    if value >= 0 and value <= @max_sequence, do: :ok, else: invalid()
  end

  defp check_value(value, :count) do
    if value >= 0 and value <= @max_sequence, do: :ok, else: invalid()
  end

  defp check_value(value, :error_code) do
    if value in @error_codes, do: :ok, else: invalid()
  end

  defp check_value(value, :error_message) do
    if byte_size(value) in 1..@max_error_message_bytes, do: :ok, else: invalid()
  end

  defp check_value(list, :participants) do
    Enum.reduce_while(list, :ok, fn entry, _acc ->
      case object(entry, @participant) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # history entries are chat.message PAYLOAD objects (§5.4), validated the same way a
  # live chat.message payload would be, and ordered strictly ascending by sequence.
  # Ascending is not the same as contiguous: §15 eviction leaves gaps.
  defp check_value(list, :history) do
    with :ok <- Enum.reduce_while(list, :ok, &history_entry/2) do
      sequences = Enum.map(list, &Map.get(&1, "sequence"))

      if sequences == Enum.sort(sequences) and sequences == Enum.uniq(sequences),
        do: :ok,
        else: invalid()
    end
  end

  defp history_entry(entry, _acc) do
    case object(entry, @chat_message_fields) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  # A nested object: presence + JSON type (V12's job) then values (V13's).
  defp object(value, fields) when is_map(value) do
    spec = %{fields: fields}

    with :ok <- v12_payload_fields(value, spec) do
      check_fields(value, fields)
    end
  end

  defp object(_value, _fields), do: invalid()

  defp pattern(value, regex, max_bytes \\ nil) do
    too_long = is_integer(max_bytes) and byte_size(value) > max_bytes

    if not too_long and Regex.match?(regex, value), do: :ok, else: invalid()
  end

  defp invalid, do: {:error, :invalid_message, false}

  defp json_type?(value, :string), do: is_binary(value)
  defp json_type?(value, :integer), do: is_integer(value)
  defp json_type?(value, :array), do: is_list(value)
  defp json_type?(value, :object), do: is_map(value)
end
