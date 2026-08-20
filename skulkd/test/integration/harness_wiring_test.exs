defmodule Skulkd.Integration.HarnessWiringTest do
  @moduledoc """
  Seed test for the integration lane (ROJ-35 owns what comes after it).

  It exists for two reasons. ExUnit errors out when a path matches no `*_test.exs`
  file, so without a test here `mix test.integration` would exit 1 rather than
  "run nothing, successfully." And a CI job that is green because it ran zero
  tests is green for no reason — this asserts the lane's wiring instead, so the
  integration job proves something real from the day it is switched on.
  """
  use ExUnit.Case, async: true

  @moduletag :integration

  test "the :integration tag is excluded from the fast `mix test` loop" do
    # If this ever fails, test/test_helper.exs stopped excluding :integration and
    # ROJ-35's port-driven suite is about to start running in the fast loop.
    assert :integration in ExUnit.configuration()[:exclude]
  end
end
