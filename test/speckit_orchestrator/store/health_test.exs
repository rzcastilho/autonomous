defmodule SpeckitOrchestrator.Store.HealthTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Health

  defp start, do: start_supervised!({Health, name: nil})

  test "starts :ok and not failed" do
    h = start()
    assert Health.status(h) == :ok
    refute Health.failed?(h)
  end

  test "record_failure/2 transitions to {:failed, reason, at}" do
    h = start()
    assert Health.record_failure(h, :write_timeout) == :ok
    assert {:failed, :write_timeout, %DateTime{}} = Health.status(h)
    assert Health.failed?(h)
  end

  test "clear/1 transitions back to :ok — operator action only" do
    h = start()
    Health.record_failure(h, :write_timeout)
    assert Health.failed?(h)

    assert Health.clear(h) == :ok
    assert Health.status(h) == :ok
    refute Health.failed?(h)
  end

  test "ok -> failed -> ok full cycle" do
    h = start()
    refute Health.failed?(h)

    Health.record_failure(h, {:aborted, :disk_full})
    assert Health.failed?(h)

    Health.clear(h)
    refute Health.failed?(h)
  end

  test "a second record_failure/2 while already failed overwrites the reason and timestamp" do
    h = start()
    Health.record_failure(h, :first)
    {:failed, :first, first_at} = Health.status(h)

    Health.record_failure(h, :second)
    assert {:failed, :second, second_at} = Health.status(h)
    assert DateTime.compare(second_at, first_at) in [:eq, :gt]
  end
end
