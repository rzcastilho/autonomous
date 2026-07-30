defmodule SpeckitOrchestrator.StackTrackerTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.StackTracker

  test "seeds with the base and an empty chain, then grows the chain as features complete" do
    {:ok, t} = StackTracker.start_link("main")
    assert StackTracker.base(t) == "main"
    assert StackTracker.chain(t) == []

    assert :ok = StackTracker.push(t, "feature/001-core")
    assert StackTracker.chain(t) == ["feature/001-core"]

    assert :ok = StackTracker.push(t, "feature/002-next")
    # Newest first — the facade walks this order looking for the first link
    # that is still unmerged.
    assert StackTracker.chain(t) == ["feature/002-next", "feature/001-core"]

    # The base is never a chain member and never changes.
    assert StackTracker.base(t) == "main"

    StackTracker.stop(t)
  end

  test ":chain seeds a resumed run's already-completed branches" do
    {:ok, t} = StackTracker.start_link("main", chain: ["feature/002-b", "feature/001-a"])

    assert StackTracker.chain(t) == ["feature/002-b", "feature/001-a"]
    assert :ok = StackTracker.push(t, "feature/003-c")

    assert StackTracker.chain(t) == ["feature/003-c", "feature/002-b", "feature/001-a"]

    StackTracker.stop(t)
  end
end
