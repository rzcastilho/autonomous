defmodule SpeckitOrchestrator.Workers.BoundTest do
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Workers.Bound

  @call_grace_ms :timer.minutes(2)
  @finalize_margin_ms :timer.seconds(30)

  setup do
    previous = Application.get_env(:speckit_orchestrator, :phase_timeout)
    Application.put_env(:speckit_orchestrator, :phase_timeout, :timer.minutes(50))

    on_exit(fn ->
      if previous do
        Application.put_env(:speckit_orchestrator, :phase_timeout, previous)
      else
        Application.delete_env(:speckit_orchestrator, :phase_timeout)
      end
    end)

    :ok
  end

  test "nil deadline uses Config.phase_timeout/0" do
    now = DateTime.utc_now()

    assert Bound.wait_ms(nil, now) ==
             :timer.minutes(50) + @call_grace_ms + @finalize_margin_ms
  end

  test "past deadline clamps remaining to 0" do
    now = DateTime.utc_now()
    deadline_at = DateTime.add(now, -60, :second)

    assert Bound.wait_ms(deadline_at, now) == @call_grace_ms + @finalize_margin_ms
  end

  test "future deadline adds the full remaining time" do
    now = DateTime.utc_now()
    deadline_at = DateTime.add(now, 120, :second)

    assert Bound.wait_ms(deadline_at, now) ==
             :timer.seconds(120) + @call_grace_ms + @finalize_margin_ms
  end

  test "opts override the grace and finalize margin" do
    now = DateTime.utc_now()
    deadline_at = DateTime.add(now, 10, :second)

    assert Bound.wait_ms(deadline_at, now, call_grace_ms: 1_000, finalize_margin_ms: 500) ==
             :timer.seconds(10) + 1_000 + 500
  end
end
