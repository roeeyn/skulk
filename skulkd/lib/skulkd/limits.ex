defmodule Skulkd.Limits do
  @moduledoc """
  Spec §8's hard bounds, and the §7.4 configuration that overrides them.

  These are capacity limits, not rate limits. §19 says the relay does no rate
  limiting at M1, and §2 principle 6 says that absence "must not imply unbounded
  rooms, participants, or history" — this module is where the second half of that
  sentence is written down.

  Every bound is read at call time rather than compiled in, so a deployment can set
  it in `config/*.exs` and a test can set it for one example:

      config :skulkd, max_rooms: 500

  §7.4 spells the same bounds as flags on a `skulkd` binary (`--max-rooms` and
  friends). That binary does not exist yet — the relay runs under `mix run` — so
  the flag names are mirrored in the key names here and the parsing lands with
  packaging at M5.

  Two §8 bounds are deliberately absent: the `4096`-byte `text` bound and the
  `16384`-byte frame bound live in `Skulkd.Protocol` as compile-time constants.
  They are half of a cross-language contract — the Go client carries the same two
  numbers, and `docs/protocol/corpus/` fails CI if the two implementations
  disagree — so making them runtime-configurable on one side only would let a
  relay drift out of the corpus it is checked against.
  """

  # The table in §8, verbatim.
  @defaults %{
    room_ttl_ms: :timer.hours(120),
    max_rooms: 10_000,
    max_members_per_room: 32,
    max_history_messages: 1_000,
    max_history_bytes: 4 * 1024 * 1024,
    max_total_history_bytes: 512 * 1024 * 1024
  }

  @doc "Room inactivity TTL (§8: `120h`). Only an accepted chat message refreshes it (§14)."
  @spec room_ttl_ms() :: pos_integer()
  def room_ttl_ms, do: get(:room_ttl_ms)

  @doc "Maximum active rooms (§8: `10,000`)."
  @spec max_rooms() :: pos_integer()
  def max_rooms, do: get(:max_rooms)

  @doc "Maximum connected participants per room (§8: `32`)."
  @spec max_members_per_room() :: pos_integer()
  def max_members_per_room, do: get(:max_members_per_room)

  @doc """
  Maximum retained messages per room (§8: `1,000`).

  Enforced by eviction rather than rejection (§15) — ROJ-41.
  """
  @spec max_history_messages() :: pos_integer()
  def max_history_messages, do: get(:max_history_messages)

  @doc """
  Maximum retained encoded history per room (§8: `4 MiB`).

  Enforced by eviction rather than rejection (§15) — ROJ-41.
  """
  @spec max_history_bytes() :: pos_integer()
  def max_history_bytes, do: get(:max_history_bytes)

  @doc "Maximum retained encoded history across all rooms (§8: `512 MiB`)."
  @spec max_total_history_bytes() :: pos_integer()
  def max_total_history_bytes, do: get(:max_total_history_bytes)

  defp get(key), do: Application.get_env(:skulkd, key, Map.fetch!(@defaults, key))
end
