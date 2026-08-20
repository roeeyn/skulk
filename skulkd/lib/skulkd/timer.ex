defmodule Skulkd.Timer do
  @moduledoc """
  The scheduling seam.

  Design A14: "injecting a clock alone cannot fake `send_after`." An injected clock
  answers *what time is it*; it has no say over when the VM delivers a scheduled
  message. Room TTLs are measured in hours, so a test that cannot control delivery
  either sleeps for hours or does not test the boundary at all.

  Production uses `Skulkd.Timer.System`; tests use `Skulkd.Timer.Manual`, which
  schedules nothing and lets the test deliver `:ttl_check` itself.
  """

  @callback send_after(
              dest :: pid() | atom(),
              message :: term(),
              milliseconds :: non_neg_integer()
            ) ::
              reference()
  @callback cancel(reference()) :: non_neg_integer() | false
end

defmodule Skulkd.Timer.System do
  @moduledoc "The real scheduler: `Process.send_after/3`."

  @behaviour Skulkd.Timer

  @impl true
  def send_after(dest, message, milliseconds), do: Process.send_after(dest, message, milliseconds)

  @impl true
  def cancel(ref), do: Process.cancel_timer(ref)
end
