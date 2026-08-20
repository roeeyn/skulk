defmodule Skulkd.Clock.Fake do
  @moduledoc """
  A clock the test controls, for TTL boundary tests (spec §22.1, design A14).

  Agent-backed and passed as a plain zero-arity function, so each test owns its own
  clock and the suite stays `async: true`.

      {:ok, clock} = Skulkd.Clock.Fake.start_link()
      {:ok, session} = Skulkd.Rooms.create(id, pw, clock: Skulkd.Clock.Fake.fun(clock))
      Skulkd.Clock.Fake.advance(clock, :timer.hours(121))
  """

  @doc "Starts a clock pinned to a fixed, reproducible instant."
  def start_link(at \\ ~U[2026-08-20 14:00:00.000Z]) do
    Agent.start_link(fn -> at end)
  end

  @doc "The zero-arity function to hand to `Skulkd.Rooms`."
  def fun(agent), do: fn -> Agent.get(agent, & &1) end

  @doc "Moves the clock forward. Nothing else in the system observes real time."
  def advance(agent, milliseconds) do
    Agent.update(agent, &DateTime.add(&1, milliseconds, :millisecond))
  end
end
