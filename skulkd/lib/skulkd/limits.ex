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
    max_total_history_bytes: 512 * 1024 * 1024,
    # §21 and design A13 rather than §8's table.
    max_member_backlog: 500
  }

  @doc """
  Every bound and its default, as a map.

  Public because `Skulkd.Config` is checked against it: a bound added here
  without an environment variable there is a limit no deployment can change, and
  a test fails rather than a deployer discovering it.
  """
  @spec defaults() :: %{atom() => pos_integer()}
  def defaults, do: @defaults

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

  Enforced by evicting the oldest message rather than by refusing the new one
  (§15).
  """
  @spec max_history_messages() :: pos_integer()
  def max_history_messages, do: get(:max_history_messages)

  @doc """
  Maximum retained encoded history per room (§8: `4 MiB`).

  Enforced by eviction (§15), except for one case that eviction cannot solve: a
  single message whose encoded size exceeds this whole bound is refused with
  `message_too_large` rather than emptying the room to make it fit.
  """
  @spec max_history_bytes() :: pos_integer()
  def max_history_bytes, do: get(:max_history_bytes)

  @doc """
  Maximum frames queued for one member before the relay disconnects it.

  Not one of §8's numbers. §21 requires a bound — "slow clients MUST not block a
  room's broadcast loop indefinitely" — and leaves the figure to the
  implementation; design A13 picked `500`.

  **Best-effort, and it matters that it is described that way.**
  `Process.info(pid, :message_queue_len)` is a snapshot, and frames beyond it sit
  in Bandit's socket write buffer and the kernel's send buffer, neither of which
  the relay can see. The guarantee is that runaway growth is cut off, not an exact
  byte ceiling. A bound described as exact when it is approximate is worse than no
  bound, because someone will reason about it.
  """
  @spec max_member_backlog() :: pos_integer()
  def max_member_backlog, do: get(:max_member_backlog)

  @doc "Maximum retained encoded history across all rooms (§8: `512 MiB`)."
  @spec max_total_history_bytes() :: pos_integer()
  def max_total_history_bytes, do: get(:max_total_history_bytes)

  defp get(key), do: Application.get_env(:skulkd, key, Map.fetch!(@defaults, key))
end
