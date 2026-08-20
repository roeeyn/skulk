defmodule Skulkd.CIRedCheckTest do
  # TEMPORARY — ROJ-37 acceptance criterion: "a deliberately broken test on a branch
  # turns the PR red (verify once, then revert)". Reverted immediately after CI shows
  # red. Untagged, so it lands inside `mix test --exclude pending_codec`.
  use ExUnit.Case, async: true

  test "deliberate failure: proving the relay job's green gate is load-bearing" do
    assert 1 == 2
  end
end
