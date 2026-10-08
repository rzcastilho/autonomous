defmodule Autonomous.WorkspaceTrust.CollectorTest do
  use ExUnit.Case, async: true

  alias Autonomous.WorkspaceTrust.Collector

  test "accumulates lines in order and returns them" do
    pid = Collector.start()
    Collector.push(pid, "a")
    Collector.push(pid, "b")
    assert Collector.lines(pid) == ["a", "b"]
    assert Collector.lines(pid) == ["a", "b"]
    Collector.stop(pid)
  end

  test "collect/1 reads then stops" do
    pid = Collector.start()
    ref = Process.monitor(pid)
    Collector.push(pid, "x")
    assert Collector.collect(pid) == ["x"]
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  test "push to a stopped collector is dropped without raising" do
    pid = Collector.start()
    ref = Process.monitor(pid)
    Collector.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    assert Collector.push(pid, "late") == :ok
    assert Collector.lines(pid) == []
  end

  test "nil collector is a no-op" do
    assert Collector.push(nil, "x") == :ok
    assert Collector.lines(nil) == []
    assert Collector.collect(nil) == []
  end
end
