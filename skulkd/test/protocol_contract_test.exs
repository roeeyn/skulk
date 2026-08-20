# Contract test for the protocol v0 golden frame corpus (ticket ROJ-29, milestone M0).
#
# This is the Elixir half of the cross-language schema contract described in design
# amendment A13: the Elixir relay and the Go client implement independent codecs and
# must accept/reject every vector in docs/protocol/corpus/ identically, with identical
# error codes. The Go half is internal/protocol/protocol_test.go.
#
# STATE AT THE END OF ROJ-29: the corpus-integrity tests pass; the codec tests fail,
# because Skulkd.Protocol does not exist yet — that is ROJ-32 (M0-4). The failure is
# deliberate and is this ticket's deliverable. To turn it green, ROJ-32 implements
# Skulkd.Protocol.validate/3; nothing in this file needs to change.

defmodule Skulkd.ProtocolContractTest do
  use ExUnit.Case, async: true

  alias Skulkd.ProtocolCorpus, as: Corpus

  for path <- Corpus.files() do
    @external_resource path
  end

  @registry Corpus.registry()
  @valid Corpus.valid()
  @invalid Corpus.invalid()

  # ---------------------------------------------------------------------------
  # The seam
  #
  # The contract every skulk protocol v0 codec must satisfy (docs/protocol-v0.md
  # §7.3):
  #
  #     validate(receiver :: :relay | :client, kind :: :text | :binary, frame :: binary)
  #       :: :ok | {:error, code :: atom}
  #
  # It is parameterized by receiver role and covers every type in the registry in
  # BOTH roles — the relay never legitimately receives a chat.message, but it must
  # still reject one as a direction violation.
  # ---------------------------------------------------------------------------

  defp error_code(:ok), do: nil
  defp error_code({:error, code}) when is_atom(code), do: Atom.to_string(code)
  defp error_code({:error, code}) when is_binary(code), do: code

  defp error_code(other) do
    flunk("""
    Skulkd.Protocol.validate/3 returned #{inspect(other)}.
    The contract is :ok | {:error, code}; see docs/protocol-v0.md §7.3.
    """)
  end

  defp validate(vector) do
    {:ok, frame} = Corpus.frame_bytes(vector)
    error_code(Skulkd.Protocol.validate(Corpus.receiver(vector), Corpus.kind(vector), frame))
  end

  # ---------------------------------------------------------------------------
  # Pass 1 — corpus integrity. Passes today, and must keep passing: it is what
  # makes the codec failures below trustworthy.
  # ---------------------------------------------------------------------------

  describe "corpus integrity" do
    @error_codes MapSet.new(@registry["error_codes"])
    @rules MapSet.new(@registry["validation_rules"])
    @directions Map.new(@registry["frame_types"], &{&1["type"], &1["directions"]})

    test "registry declares protocol version 0" do
      assert @registry["protocol_version"] == 0
    end

    for vector <- @valid ++ @invalid do
      @vector vector
      @want_result if vector in @valid, do: "accept", else: "reject"

      test "#{Path.basename(Path.dirname(vector["path"]))}/#{vector["name"]} is well formed" do
        vector = @vector

        assert vector["name"] == Path.basename(vector["path"], ".json"),
               "name does not match filename"

        assert is_binary(vector["description"]) and vector["description"] != ""
        assert vector["direction"] in ["c2r", "r2c"]

        want_receiver = if vector["direction"] == "c2r", do: "relay", else: "client"

        assert vector["receiver"] == want_receiver,
               "receiver #{vector["receiver"]} contradicts direction #{vector["direction"]}"

        assert vector["expect"]["result"] == @want_result
        assert vector["wire"]["kind"] in ["text", "binary"]

        if vector["wire"]["kind"] == "binary" do
          assert is_binary(vector["wire"]["base64"]), "binary frames must use wire.base64"
        end

        assert match?({:ok, _}, Corpus.frame_bytes(vector)),
               "wire bytes cannot be reconstructed"

        case @want_result do
          "accept" ->
            refute vector["expect"]["error_code"], "a valid vector must not annotate error_code"
            refute vector["expect"]["rule"], "a valid vector must not annotate rule"

            assert is_binary(vector["frame_type"]), "a valid vector must name its frame_type"
            dirs = Map.fetch!(@directions, vector["frame_type"])

            assert vector["direction"] in dirs,
                   "#{vector["frame_type"]} does not travel #{vector["direction"]} per registry.json"

          "reject" ->
            assert MapSet.member?(@error_codes, vector["expect"]["error_code"]),
                   "error_code #{inspect(vector["expect"]["error_code"])} is not in registry.json"

            assert MapSet.member?(@rules, vector["expect"]["rule"]),
                   "rule #{inspect(vector["expect"]["rule"])} is not in registry.json"

            if vector["frame_type"] do
              assert Map.has_key?(@directions, vector["frame_type"]),
                     "frame_type is not in registry.json (use null when the frame is too broken to have one)"
            end
        end
      end
    end

    test "every registry type and direction has a valid vector" do
      covered =
        MapSet.new(@valid, fn v -> {v["frame_type"], v["direction"]} end)

      missing =
        for %{"type" => type, "directions" => dirs} <- @registry["frame_types"],
            dir <- dirs,
            not MapSet.member?(covered, {type, dir}),
            do: "#{type} #{dir}"

      assert missing == [], "no valid vector for: #{Enum.join(missing, ", ")}"
    end

    test "every validation rule has an invalid vector" do
      covered = MapSet.new(@invalid, & &1["expect"]["rule"])

      missing =
        Enum.reject(@registry["validation_rules"], &MapSet.member?(covered, &1))

      assert missing == [], "no invalid vector exercises: #{Enum.join(missing, ", ")}"
    end

    # ROJ-29 acceptance criteria, checked mechanically so they cannot rot.
    test "acceptance criteria" do
      assert length(@invalid) >= 10, "ticket requires at least 10 invalid vectors"
      assert length(@registry["error_codes"]) == 10, "protocol v0 defines exactly 10 error codes"
      assert length(@registry["frame_types"]) == 13, "protocol v0 defines exactly 13 frame types"
    end
  end

  # ---------------------------------------------------------------------------
  # Pass 2 and 3 — the codec contract. Both fail until ROJ-32 lands.
  # ---------------------------------------------------------------------------

  describe "valid vectors are accepted" do
    for vector <- @valid do
      @vector vector

      test vector["name"] do
        vector = @vector

        assert validate(vector) == nil,
               """
               frame rejected, must be accepted
                 #{vector["description"]}
                 #{vector["path"]}
               """
      end
    end
  end

  describe "invalid vectors close the connection exactly when the rule says so" do
    # Promised by docs/protocol/corpus/README.md: "Wire up this assertion when
    # transport lands in ROJ-32/ROJ-33." close? is a property of the RULE, not the
    # code — message_too_large closes on V2 (oversized frame) but not on V13
    # (oversized text), and unsupported_frame_type closes on V1 (binary) but not V8
    # (unknown type). Skulkd.Conn reads this to decide whether to hang up.
    for vector <- @invalid do
      @vector vector

      test vector["name"] do
        vector = @vector
        {:ok, frame} = Corpus.frame_bytes(vector)

        assert {:error, _code, close?} =
                 Skulkd.Protocol.decode(Corpus.receiver(vector), Corpus.kind(vector), frame)

        assert close? == vector["expect"]["close"],
               """
               wrong close behaviour: got #{close?}, want #{vector["expect"]["close"]} (rule #{vector["expect"]["rule"]})
                 #{vector["description"]}
                 #{vector["path"]}
               """
      end
    end
  end

  describe "invalid vectors are rejected with the annotated code" do
    for vector <- @invalid do
      @vector vector

      test vector["name"] do
        vector = @vector
        want = vector["expect"]["error_code"]
        got = validate(vector)

        # Exact equality, not mere rejection: identical codes across the two
        # languages ARE the contract (A13).
        assert got == want,
               """
               wrong error code: got #{inspect(got)}, want #{inspect(want)} (rule #{vector["expect"]["rule"]})
                 #{vector["description"]}
                 #{vector["path"]}
               """
      end
    end
  end
end
