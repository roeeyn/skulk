defmodule Skulkd.ProtocolPropertyTest do
  @moduledoc """
  ROJ-44 (M1-6): spec §22.3's fuzz/property requirement on frame decoding.

  `stream_data` has been a dependency since the first commit and had never been
  used. The golden corpus proves the two codecs agree on the cases somebody thought
  of; these attack the ones nobody did.

  This file is the single-language half — properties `Skulkd.Protocol` must satisfy
  on its own. The cross-language half, where generated frames go through *both*
  codecs and the verdicts are compared, is
  `test/integration/protocol_differential_test.exs`, because it needs a Go binary.

  ## Runs

  Bounded so the normal suite stays fast. `PROPERTY_RUNS` raises it for a campaign:

      PROPERTY_RUNS=50000 mix test test/skulkd/protocol_property_test.exs

  That campaign — 300,000 cases across these six properties, 328 seconds — is what
  the current shape of this file survived. It found one thing, and it was a bug in
  a property rather than in the codec: see the frame-size guard in the D3 property.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  # ExUnit's default 60s wall is fine for the bounded run and far too short for a
  # campaign, and a campaign that reports a timeout as a failure is a campaign
  # nobody trusts.
  @moduletag timeout: 1_800_000

  alias Skulkd.Frames
  alias Skulkd.Protocol
  alias Skulkd.ProtocolCorpus, as: Corpus

  @runs String.to_integer(System.get_env("PROPERTY_RUNS") || "200")

  @valid Corpus.valid()
  @codes MapSet.new(Protocol.error_codes())

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Pure noise. Only ever reaches V3/V4 — both codecs reject essentially all of it —
  # so this is the no-crash generator, not the disagreement-hunting one.
  defp junk do
    one_of([
      binary(),
      map(binary(), &("{" <> &1)),
      map(list_of(integer(0..255), max_length: 200), &:erlang.list_to_binary/1),
      string(:printable)
    ])
  end

  # Frames built by mutating a valid corpus vector, which is what concentrates
  # cases at the accept/reject boundary where the interesting behaviour lives.
  # Design A13 says the corpus seeds this; random bytes never get past V4.
  defp mutated_vector do
    gen all(
          vector <- member_of(@valid),
          {:ok, bytes} = Corpus.frame_bytes(vector),
          mutation <- mutation(byte_size(bytes))
        ) do
      {vector, apply_mutation(bytes, mutation)}
    end
  end

  defp mutation(size) do
    one_of([
      tuple({constant(:flip), integer(0..max(size - 1, 0)), integer(1..255)}),
      tuple({constant(:truncate), integer(0..max(size - 1, 0))}),
      tuple({constant(:insert), integer(0..size), integer(0..255)}),
      tuple({constant(:duplicate_tail), integer(0..max(size - 1, 0))}),
      constant({:append_junk})
    ])
  end

  defp apply_mutation(bytes, {:flip, at, xor}) do
    <<head::binary-size(at), byte, tail::binary>> = bytes
    <<head::binary, Bitwise.bxor(byte, xor), tail::binary>>
  rescue
    MatchError -> bytes
  end

  defp apply_mutation(bytes, {:truncate, at}), do: binary_part(bytes, 0, at)

  defp apply_mutation(bytes, {:insert, at, byte}) do
    <<binary_part(bytes, 0, at)::binary, byte,
      binary_part(bytes, at, byte_size(bytes) - at)::binary>>
  end

  defp apply_mutation(bytes, {:duplicate_tail, at}) do
    bytes <> binary_part(bytes, at, byte_size(bytes) - at)
  end

  defp apply_mutation(bytes, {:append_junk}), do: bytes <> "}]"

  defp verdict(receiver, kind, frame) do
    Protocol.validate(receiver, kind, frame)
  rescue
    error -> {:crash, error}
  catch
    kind, value -> {:crash, {kind, value}}
  end

  # ---------------------------------------------------------------------------
  property "no input crashes the validator — every frame gets a verdict" do
    check all(
            frame <- junk(),
            receiver <- member_of([:relay, :client]),
            kind <- member_of([:text, :binary]),
            max_runs: @runs
          ) do
      case verdict(receiver, kind, frame) do
        :ok -> :ok
        {:error, code} when is_atom(code) -> :ok
        other -> flunk("#{inspect(other)} for #{inspect(frame, limit: 40)}")
      end
    end
  end

  property "every rejection names a code from the §6 registry" do
    check all(
            {_vector, frame} <- mutated_vector(),
            receiver <- member_of([:relay, :client]),
            max_runs: @runs
          ) do
      case verdict(receiver, :text, frame) do
        :ok ->
          :ok

        {:error, code} ->
          assert MapSet.member?(@codes, Atom.to_string(code)),
                 "#{code} is not one of the eleven codes in §6"

        other ->
          flunk("#{inspect(other)} for #{inspect(frame, limit: 40)}")
      end
    end
  end

  property "a mutated vector never crashes the validator either" do
    check all(
            {_vector, frame} <- mutated_vector(),
            receiver <- member_of([:relay, :client]),
            kind <- member_of([:text, :binary]),
            max_runs: @runs
          ) do
      refute match?({:crash, _}, verdict(receiver, kind, frame))
    end
  end

  property "unknown fields are ignored at every depth (decision D3)" do
    # D3 pins §16.1's MAY to a MUST, so this is a property rather than the three
    # examples the corpus can afford to carry.
    check all(
            vector <- member_of(Enum.filter(@valid, &(&1["wire"]["json"] != nil))),
            name <- string(:alphanumeric, min_length: 1, max_length: 12),
            value <- one_of([integer(), boolean(), string(:alphanumeric)]),
            where <- member_of([:envelope, :payload]),
            max_runs: @runs
          ) do
      original = vector["wire"]["json"]
      name = "x_" <> name

      # Never shadow a field the frame already carries: that is a different rule.
      decorated =
        case where do
          :envelope -> Map.put_new(original, name, value)
          :payload -> put_in(original, ["payload"], Map.put_new(original["payload"], name, value))
        end

      receiver = Corpus.receiver(vector)
      encoded = Jason.encode!(decorated)

      assert Protocol.validate(receiver, :text, Jason.encode!(original)) == :ok

      # A long campaign found this the honest way: `chat-send-max-text` already
      # sits at §4's 4,096-byte text bound, so decorating it can push the whole
      # FRAME past V2's 16,384-byte cap — and `message_too_large` is then the
      # correct answer rather than a D3 violation. The rule under test is that an
      # unknown field is ignored, which is only a claim about frames that are
      # otherwise legal.
      if byte_size(encoded) <= 16_384 do
        assert Protocol.validate(receiver, :text, encoded) == :ok
      end
    end
  end

  property "the text bound is counted in bytes, not runes (§4)" do
    # The bytes-not-runes rule fuzzed rather than sampled: a string of astral
    # characters is a quarter as many runes as it is bytes, so an implementation
    # measuring length would accept four times too much.
    check all(
            filler <- string([?a..?z, 0x00A9, 0x4E16, 0x1F600], min_length: 1, max_length: 60),
            max_runs: @runs
          ) do
      at_bound = pad_to(filler, 4_096)
      over = pad_to(filler, 4_096) <> "a"

      assert byte_size(at_bound) == 4_096
      assert Protocol.validate(:relay, :text, chat_send(at_bound)) == :ok
      assert Protocol.validate(:relay, :text, chat_send(over)) == {:error, :message_too_large}
    end
  end

  property "the relay never emits a frame its own validator rejects" do
    check all(
            code <- member_of(Protocol.error_codes()),
            request_id <-
              one_of([constant(nil), constant("3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13")]),
            max_runs: @runs
          ) do
      frame = code |> String.to_existing_atom() |> Frames.error(request_id) |> Jason.encode!()
      assert Protocol.validate(:client, :text, frame) == :ok
    end
  end

  # ---------------------------------------------------------------------------

  # Repeats `filler` and trims to exactly `bytes` bytes without splitting a
  # character — which is the whole point, since a split one would be invalid UTF-8
  # and get rejected by V3 for the wrong reason.
  defp pad_to(filler, bytes) do
    filler
    |> List.duplicate(div(bytes, byte_size(filler)) + 2)
    |> Enum.join()
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      next = size + byte_size(grapheme)
      if next > bytes, do: {:halt, {acc, size}}, else: {:cont, {[grapheme | acc], next}}
    end)
    |> then(fn {acc, size} ->
      Enum.join(Enum.reverse(acc)) <> String.duplicate("a", bytes - size)
    end)
  end

  defp chat_send(text) do
    Jason.encode!(%{
      "v" => 0,
      "type" => "chat.send",
      "request_id" => "3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",
      "payload" => %{"message_id" => "9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846", "text" => text}
    })
  end
end
