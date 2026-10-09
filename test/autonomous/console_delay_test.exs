defmodule Autonomous.ConsoleDelayTest do
  use ExUnit.Case, async: true

  alias Autonomous.ConsoleDelay

  test "step/2 resets on success or none, counts errors" do
    assert ConsoleDelay.step(3, {:ok, %{}}) == 0
    assert ConsoleDelay.step(3, :none) == 0
    assert ConsoleDelay.step(0, {:error, :timeout}) == 1
    assert ConsoleDelay.step(2, {:error, :down}) == 3
  end

  test "delayed?/1 from the second consecutive miss" do
    refute ConsoleDelay.delayed?(0)
    refute ConsoleDelay.delayed?(1)
    assert ConsoleDelay.delayed?(2)
    assert ConsoleDelay.delayed?(9)
  end

  test "broadcast?/2" do
    assert ConsoleDelay.broadcast?(0, {:ok, %{}}) == :reconciled
    assert ConsoleDelay.broadcast?(0, :none) == :reconciled
    assert ConsoleDelay.broadcast?(1, {:error, :timeout}) == :silent
    assert ConsoleDelay.broadcast?(2, {:error, :timeout}) == :delayed
  end

  test "log?/4" do
    assert ConsoleDelay.log?(0, 1, nil, 0) == :warn
    assert ConsoleDelay.log?(1, 2, 0, 1_000) == :quiet
    assert ConsoleDelay.log?(1, 2, 0, 60_000) == :warn
    assert ConsoleDelay.log?(5, 6, nil, 10) == :warn
    assert ConsoleDelay.log?(3, 0, 0, 10) == :recovered
    assert ConsoleDelay.log?(0, 0, nil, 10) == :quiet
  end
end
