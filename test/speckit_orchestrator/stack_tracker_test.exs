defmodule SpeckitOrchestrator.StackTrackerTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.StackTracker

  test "seeds with the base, then advances the top as features complete" do
    {:ok, t} = StackTracker.start_link("main")
    assert StackTracker.top(t) == "main"

    assert :ok = StackTracker.set_top(t, "feature/001-core")
    assert StackTracker.top(t) == "feature/001-core"

    assert :ok = StackTracker.set_top(t, "feature/002-next")
    assert StackTracker.top(t) == "feature/002-next"

    StackTracker.stop(t)
  end
end
