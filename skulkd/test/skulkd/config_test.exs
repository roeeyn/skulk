defmodule Skulkd.ConfigTest do
  @moduledoc """
  ROJ-50: the relay's environment-variable interface, and the two tests that keep
  it from silently going stale.

  `Skulkd.Config` is a pure function from an environment map to a keyword list so
  that it can be tested at all — `config/runtime.exs` does nothing but call it,
  because logic inside a config file is logic no test can reach.
  """
  use ExUnit.Case, async: true

  alias Skulkd.Config
  alias Skulkd.Limits

  @example Path.expand("../../skulkd.env.example", __DIR__)
  @external_resource @example

  describe "bounds" do
    test "every §8 bound reaches application environment" do
      env = %{
        "SKULKD_ROOM_TTL_MS" => "3600000",
        "SKULKD_MAX_ROOMS" => "500",
        "SKULKD_MAX_MEMBERS_PER_ROOM" => "8",
        "SKULKD_MAX_HISTORY_MESSAGES" => "200",
        "SKULKD_MAX_HISTORY_BYTES" => "1048576",
        "SKULKD_MAX_TOTAL_HISTORY_BYTES" => "67108864",
        "SKULKD_MAX_MEMBER_BACKLOG" => "50"
      }

      assert Enum.sort(Config.from_env(env)) == [
               max_history_bytes: 1_048_576,
               max_history_messages: 200,
               max_member_backlog: 50,
               max_members_per_room: 8,
               max_rooms: 500,
               max_total_history_bytes: 67_108_864,
               room_ttl_ms: 3_600_000
             ]
    end

    test "an unset variable is left alone rather than defaulted" do
      # Config.from_env/1 must not restate Limits' defaults. If it did, the
      # default would live in two places and one of them would drift.
      assert Config.from_env(%{}) == []
      assert Config.from_env(%{"SKULKD_MAX_ROOMS" => "7"}) == [max_rooms: 7]
    end

    test "a bound that is not a positive integer fails loudly at boot" do
      for bad <- ["", "abc", "0", "-1", "12.5", "500 ", "1_000", "0x10"] do
        assert_raise ArgumentError, ~r/SKULKD_MAX_ROOMS/, fn ->
          Config.from_env(%{"SKULKD_MAX_ROOMS" => bad})
        end
      end
    end

    test "the failure names the variable and shows what it got" do
      # A relay that boots with a silently-ignored bound is worse than one that
      # refuses to boot: the operator believes a limit is in force.
      error =
        assert_raise ArgumentError, fn ->
          Config.from_env(%{"SKULKD_MAX_HISTORY_BYTES" => "4MiB"})
        end

      assert error.message =~ "SKULKD_MAX_HISTORY_BYTES"
      assert error.message =~ "4MiB"
      assert error.message =~ "positive integer"
    end
  end

  describe "SKULKD_BIND" do
    test "IP:PORT becomes an address and a port" do
      assert Config.from_env(%{"SKULKD_BIND" => "0.0.0.0:4000"}) == [ip: {0, 0, 0, 0}, port: 4000]

      assert Config.from_env(%{"SKULKD_BIND" => "127.0.0.1:8080"}) ==
               [ip: {127, 0, 0, 1}, port: 8080]
    end

    test "IPv6 is bracketed, the way a URL writes it" do
      assert Config.from_env(%{"SKULKD_BIND" => "[::1]:4000"}) ==
               [ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 4000]

      assert Config.from_env(%{"SKULKD_BIND" => "[::]:4000"}) ==
               [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4000]
    end

    test "a malformed bind refuses to boot" do
      for bad <- ["4000", "0.0.0.0", "localhost:4000", "0.0.0.0:abc", "999.1.1.1:80", "::1:4000"] do
        assert_raise ArgumentError, ~r/SKULKD_BIND/, fn ->
          Config.from_env(%{"SKULKD_BIND" => bad})
        end
      end
    end

    test "binding to loopback is expressible, because that is how you sit behind a proxy" do
      # docs/self-hosting.md tells the reader to do exactly this. If it stopped
      # working the documentation would still say to.
      assert [ip: {127, 0, 0, 1}, port: _] = Config.from_env(%{"SKULKD_BIND" => "127.0.0.1:4000"})
    end
  end

  describe "nothing goes stale" do
    test "every bound in Skulkd.Limits has an environment variable" do
      # Half of the pair. Adding a bound to Limits without adding it here would
      # ship a limit no deployment can change.
      assert Enum.sort(Map.keys(Config.bounds())) == Enum.sort(Map.keys(Limits.defaults()))
    end

    test "skulkd.env.example names every variable, with a comment above each" do
      # The other half. §24 requires an example configuration file; an example
      # that has fallen behind the code is the reason the requirement is not just
      # "write some documentation".
      example = File.read!(@example)
      variables = Map.values(Config.bounds()) ++ ["SKULKD_BIND"]

      for variable <- variables do
        assert example =~ ~r/^#\s*\S.*\n(#.*\n)*#?#{variable}=/m,
               """
               skulkd.env.example does not document #{variable}, or documents it \
               without a comment line above it.

               Every bound is a decision an operator is making; a bare KEY=VALUE \
               tells them the name and nothing about what happens if they change it.
               """
      end
    end

    test "the example file assigns nothing that looks like a secret" do
      # §24: "Example environment/configuration file containing no secrets." The
      # relay has no secret configuration today — it holds no keys and issues no
      # credentials — and this is what notices when it gains one and the example
      # file gains a plausible-looking value along with it.
      #
      # Assignments only, commented-out ones included. The prose is free to
      # discuss room passwords; a line that SETS one is the problem.
      assignments =
        @example
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(
          &Regex.run(~r/^\s*#?\s*([A-Za-z_][A-Za-z0-9_]*)=/, &1, capture: :all_but_first)
        )
        |> Enum.reject(&is_nil/1)
        |> List.flatten()

      assert assignments != [], "no assignments found — the regex or the file moved"

      for name <- assignments do
        refute name =~ ~r/(password|passphrase|secret|token|key|credential)/i,
               "#{name} is an environment variable that sets a secret, in a file that must contain none"
      end
    end
  end
end
