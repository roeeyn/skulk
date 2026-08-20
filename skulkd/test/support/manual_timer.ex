defmodule Skulkd.Timer.Manual do
  @moduledoc """
  A `Skulkd.Timer` that never actually schedules anything.

  Design A14 is explicit that an injected clock alone cannot make TTL tests
  deterministic: `Process.send_after/3` does not consult it. So the scheduler is its
  own seam, and in tests it is inert — the test advances `Skulkd.Clock.Fake` and then
  delivers the tick itself:

      send(room_pid, :ttl_check)

  Nothing here sleeps, so TTL boundary tests run in microseconds rather than hours.
  """

  @behaviour Skulkd.Timer

  @impl true
  def send_after(_dest, _message, _milliseconds), do: make_ref()

  @impl true
  def cancel(_ref), do: false
end
