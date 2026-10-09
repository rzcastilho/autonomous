defmodule Autonomous.SessionRetryTest do
  use ExUnit.Case, async: true

  alias Autonomous.SessionRetry

  @died %{session_died: %{kind: :start_failed, excerpt: "boom"}}
  @open %{retried?: false, drain?: false}

  test "retries the first death" do
    assert SessionRetry.once(@died, @open) == :retry
  end

  test "does not retry a second death" do
    assert SessionRetry.once(@died, %{@open | retried?: true}) == :accept
  end

  test "does not retry when a drain was requested" do
    assert SessionRetry.once(@died, %{@open | drain?: true}) == :accept
  end

  test "passes non-death outcomes through" do
    assert SessionRetry.once(%{}, @open) == :accept
    assert SessionRetry.once(nil, @open) == :accept
    assert SessionRetry.once(%{branch_drift: %{}}, @open) == :accept
    assert SessionRetry.once(%{session_died: nil}, @open) == :accept
  end
end
