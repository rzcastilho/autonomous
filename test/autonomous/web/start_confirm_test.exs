defmodule Autonomous.Web.StartConfirmTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.StartConfirm

  test "idle click with no active run dispatches at once" do
    assert StartConfirm.next(:idle, :click, nil) == {:idle, :dispatch}
  end

  test "idle click with an active run arms on it and does not dispatch" do
    assert StartConfirm.next(:idle, :click, "r1") == {{:armed, "r1"}, :none}
  end

  test "armed click on the same run dispatches and returns to idle" do
    assert StartConfirm.next({:armed, "r1"}, :click, "r1") == {:idle, :dispatch}
  end

  test "armed click when a different run is now active re-arms and does not dispatch" do
    assert StartConfirm.next({:armed, "r1"}, :click, "r2") == {{:armed, "r2"}, :none}
  end

  test "armed click when no run is left dispatches" do
    assert StartConfirm.next({:armed, "r1"}, :click, nil) == {:idle, :dispatch}
  end

  test "cancel returns to idle from any state without dispatching" do
    assert StartConfirm.next({:armed, "r1"}, :cancel, "r1") == {:idle, :none}
    assert StartConfirm.next(:idle, :cancel, nil) == {:idle, :none}
  end

  test "the run ending while armed disarms" do
    assert StartConfirm.next({:armed, "r1"}, {:active_run, nil}, nil) == {:idle, :none}
  end

  test "a different run appearing while armed re-arms on it" do
    assert StartConfirm.next({:armed, "r1"}, {:active_run, "r2"}, "r2") == {{:armed, "r2"}, :none}
  end

  test "the same run reported again keeps the arm" do
    assert StartConfirm.next({:armed, "r1"}, {:active_run, "r1"}, "r1") == {{:armed, "r1"}, :none}
  end

  test "an active-run update while idle stays idle" do
    assert StartConfirm.next(:idle, {:active_run, "r1"}, "r1") == {:idle, :none}
    assert StartConfirm.next(:idle, {:active_run, nil}, nil) == {:idle, :none}
  end

  test "a tab switch disarms from any state" do
    assert StartConfirm.next({:armed, "r1"}, :tab_switch, "r1") == {:idle, :none}
    assert StartConfirm.next(:idle, :tab_switch, "r1") == {:idle, :none}
  end

  test "a click from idle never dispatches while a run is active" do
    for run <- ["r1", "r2", "r000004"],
        do: assert(StartConfirm.next(:idle, :click, run) |> elem(1) == :none)
  end
end
