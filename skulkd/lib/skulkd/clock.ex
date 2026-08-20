defmodule Skulkd.Clock do
  @moduledoc """
  Wall-clock time, and the one canonical way to put it on the wire.

  A clock is any zero-arity function returning a `DateTime` — `&DateTime.utc_now/0`
  in production, `Skulkd.Clock.Fake` in tests.
  """

  @type t :: (-> DateTime.t())

  @doc "The default production clock."
  @spec system() :: t()
  def system, do: &DateTime.utc_now/0

  @doc """
  Formats an instant as protocol v0's ONLY accepted timestamp spelling:
  `YYYY-MM-DDTHH:MM:SS.sssZ` (docs/protocol-v0.md decision D5).

  The truncation is load-bearing, not cosmetic. `DateTime.utc_now/0` carries
  microsecond precision and `DateTime.to_iso8601/1` prints all six digits, which the
  corpus rejects (`invalid/timestamp-wrong-precision.json`). Beyond the corpus, D5
  exists because M4's continuity fold requires `received_at` to be byte-identical
  between a live `chat.message` and the same message replayed from a history
  snapshot — two spellings of one instant make honest clients diverge.

  Every timestamp leaving a room goes through here.
  """
  @spec to_wire(DateTime.t()) :: String.t()
  def to_wire(%DateTime{} = at) do
    at
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end
end
