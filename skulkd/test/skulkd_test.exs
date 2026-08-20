defmodule SkulkdTest do
  use ExUnit.Case
  doctest Skulkd

  test "greets the world" do
    assert Skulkd.hello() == :world
  end
end
