defmodule Skulkd.Integration.ProtocolDifferentialTest do
  @moduledoc """
  ROJ-44 (M1-6): the two codecs, asked the same question about frames nobody wrote.

  Design A13 gives skulk two independent protocol implementations, and
  `docs/protocol/corpus/` checks they agree on 64 vectors somebody thought of.
  This checks they agree on generated ones — which is the same contract, machine-
  checked instead of sampled.

  The oracle (`cmd/protocol-oracle`) is a long-lived Go process holding
  `protocol.Validate`, the exact seam the Go corpus test uses, so a verdict here
  speaks for the code that ships.

  ## What it found

  Two genuine divergences, both now fixed and frozen as corpus vectors:

  * **Duplicate keys.** Go's `encoding/json` keeps the last occurrence, Jason keeps
    the first, so `{"text":"harmless","text":"actual"}` was a frame the relay
    validated as one thing and every client displayed as another. Rejected outright
    by decision D13 rather than picking a winner.
  * **Unpaired surrogate escapes.** `\\ud800` survives V3's UTF-8 scan and is
    resolved during parsing, where Go substituted U+FFFD and accepted while Jason
    rejected. V3 had already decided it; the Go codec was out of spec.

  ## What was searched, so that "nothing further" means something

  The suite runs 300 cases per property by default, and `PROPERTY_RUNS` raises it:

      PROPERTY_RUNS=30000 mix test.integration --only differential

  The campaign behind this file's findings was `PROPERTY_RUNS=30000` — roughly
  120,000 frames, 213 seconds — over four generators: every corpus vector
  byte-mutated (flip, truncate, insert, splice, and appended `}`, `\\ud800`, `""`),
  arbitrary binaries, structurally plausible frames built field by field from the
  registry, and targeted duplicate-key and surrogate spellings. Both receiver
  roles, both frame kinds.

  It found nothing beyond the four already fixed. Two things that search does NOT
  cover, and it would be dishonest to imply otherwise: generated frames rarely
  exceed a few kilobytes, so the 16 KiB relay bound is exercised by the corpus
  rather than by fuzzing; and §22.3's canonical AAD encoding does not exist until
  M3, so that half of the requirement is unaddressed by construction.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skulkd.Protocol
  alias Skulkd.ProtocolCorpus, as: Corpus
  alias Skulkd.ProtocolOracle

  @moduletag :integration
  @moduletag :differential
  @moduletag timeout: 600_000

  @runs String.to_integer(System.get_env("PROPERTY_RUNS") || "300")
  @valid Corpus.valid()
  @invalid Corpus.invalid()

  setup_all do
    # One process for the whole file. A process per frame would spend milliseconds
    # of fork on a microsecond of validation.
    {:ok, oracle} = ProtocolOracle.start_link()
    %{oracle: oracle}
  end

  # ---------------------------------------------------------------------------

  defp elixir_verdict(receiver, kind, frame) do
    case Protocol.validate(receiver, kind, frame) do
      :ok -> "ok"
      {:error, code} -> Atom.to_string(code)
    end
  rescue
    error -> "RAISED #{inspect(error.__struct__)}"
  catch
    kind, value -> "THREW #{inspect({kind, value})}"
  end

  defp compare(oracle, receiver, kind, frame) do
    mine = elixir_verdict(receiver, kind, frame)

    theirs =
      case ProtocolOracle.verdict(oracle, receiver, kind, frame) do
        :ok -> "ok"
        {:crash, detail} -> "CRASHED: #{detail}"
        {:timeout, detail} -> "HUNG: #{detail}"
        code -> code
      end

    assert mine == theirs, """
    The two codecs disagree.

      receiver: #{receiver}
      kind:     #{kind}
      elixir:   #{mine}
      go:       #{theirs}

    Reproduce with this frame (base64):
      #{Base.encode64(frame)}

    A disagreement is a bug in one of them — docs/protocol-v0.md decides which.
    Freeze it as a corpus vector once both agree.
    """
  end

  defp mutation(size) do
    one_of([
      tuple({constant(:flip), integer(0..max(size - 1, 0)), integer(1..255)}),
      tuple({constant(:truncate), integer(0..max(size - 1, 0))}),
      tuple({constant(:insert), integer(0..size), integer(0..255)}),
      tuple({constant(:splice), integer(0..max(size - 1, 0)), binary(max_length: 8)}),
      constant({:append, "}"}),
      constant({:append, "\\ud800"}),
      constant({:append, "\"\""})
    ])
  end

  defp apply_mutation(bytes, {:flip, at, xor}) when byte_size(bytes) > at do
    <<head::binary-size(at), byte, tail::binary>> = bytes
    <<head::binary, Bitwise.bxor(byte, xor), tail::binary>>
  end

  defp apply_mutation(bytes, {:truncate, at}),
    do: binary_part(bytes, 0, min(at, byte_size(bytes)))

  defp apply_mutation(bytes, {:insert, at, byte}) when byte_size(bytes) >= at do
    <<binary_part(bytes, 0, at)::binary, byte,
      binary_part(bytes, at, byte_size(bytes) - at)::binary>>
  end

  defp apply_mutation(bytes, {:splice, at, chunk}) when byte_size(bytes) > at do
    <<binary_part(bytes, 0, at)::binary, chunk::binary,
      binary_part(bytes, at, byte_size(bytes) - at)::binary>>
  end

  defp apply_mutation(bytes, {:append, suffix}), do: bytes <> suffix
  defp apply_mutation(bytes, _), do: bytes

  defp corpus_bytes do
    gen all(vector <- member_of(@valid ++ @invalid)) do
      {:ok, bytes} = Corpus.frame_bytes(vector)
      bytes
    end
  end

  # ---------------------------------------------------------------------------
  describe "the corpus, through both codecs at once" do
    test "every vector gets the same verdict from both", %{oracle: oracle} do
      # The contract suites already check each codec against the annotations. This
      # checks them against EACH OTHER, which is the property that survives an
      # annotation being wrong in both files.
      for vector <- @valid ++ @invalid do
        {:ok, bytes} = Corpus.frame_bytes(vector)
        compare(oracle, Corpus.receiver(vector), Corpus.kind(vector), bytes)
      end
    end
  end

  describe "generated frames" do
    property "mutated corpus vectors get identical verdicts", %{oracle: oracle} do
      # Mutating known-good frames is what concentrates cases at the accept/reject
      # boundary. Pure random bytes never get past V4, where both codecs trivially
      # agree that garbage is garbage.
      check all(
              bytes <- corpus_bytes(),
              mutation <- mutation(byte_size(bytes)),
              receiver <- member_of([:relay, :client]),
              max_runs: @runs
            ) do
        compare(oracle, receiver, :text, apply_mutation(bytes, mutation))
      end
    end

    property "arbitrary bytes get identical verdicts", %{oracle: oracle} do
      check all(
              frame <- one_of([binary(), string(:printable), string(:ascii)]),
              receiver <- member_of([:relay, :client]),
              kind <- member_of([:text, :binary]),
              max_runs: @runs
            ) do
        compare(oracle, receiver, kind, frame)
      end
    end

    property "structurally plausible frames get identical verdicts", %{oracle: oracle} do
      # Frames that are the right SHAPE but wrong in one field reach V5-V13, which
      # is where the two codecs have the most room to differ: type coercion, number
      # spelling, pattern matching, cross-field invariants.
      check all(
              v <- one_of([constant(0), integer(), constant("0"), constant(nil)]),
              type <- one_of([member_of(Protocol.frame_types()), string(:alphanumeric)]),
              request_id <-
                one_of([
                  constant("3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13"),
                  constant(nil),
                  string(:alphanumeric, max_length: 40)
                ]),
              payload <- payload(),
              receiver <- member_of([:relay, :client]),
              max_runs: @runs
            ) do
        frame =
          Jason.encode!(%{
            "v" => v,
            "type" => type,
            "request_id" => request_id,
            "payload" => payload
          })

        compare(oracle, receiver, :text, frame)
      end
    end

    property "duplicate keys and surrogate escapes stay agreed (D13)", %{oracle: oracle} do
      # The two findings, kept under fire. Both were divergences before D13, so a
      # regression in either codec shows up here rather than in production.
      check all(
              key <- member_of(~w(v type request_id payload text message_id)),
              first <- one_of([constant(0), string(:alphanumeric, max_length: 8), constant(nil)]),
              escape <- member_of(~w(\\ud800 \\udc00 \\ud83d \\ud83d\\ude00 \\ufffd)),
              max_runs: @runs
            ) do
        duplicated =
          ~s({"v":0,"type":"chat.send","request_id":"3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",) <>
            ~s("#{key}":#{Jason.encode!(first)},"payload":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846","text":"a"}})

        surrogate =
          ~s({"v":0,"type":"chat.send","request_id":"3f2a7c1e-9b4d-4e28-8a51-6c0d2e7f9b13",) <>
            ~s("payload":{"message_id":"9c1e5a20-4b7d-4f61-b8e3-2d5a7c0f1846","text":"#{escape}"}})

        compare(oracle, :relay, :text, duplicated)
        compare(oracle, :relay, :text, surrogate)
      end
    end
  end

  defp payload do
    one_of([
      constant(%{}),
      constant(nil),
      map_of(
        string(:alphanumeric, max_length: 12),
        one_of([integer(), string(:printable), boolean()]),
        max_length: 4
      ),
      constant([]),
      constant("string payload")
    ])
  end
end
