defmodule Autonomous.Web.RunStateViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.{CoreComponents, RunStateView}

  test "status/1 maps run states and outcomes" do
    assert RunStateView.status(:in_flight) == "running"
    assert RunStateView.status(:completed) == "done"
    assert RunStateView.status(:parked) == "escalated"
    assert RunStateView.status(:superseded) == "blocked"
    assert RunStateView.status(:interrupted) == "blocked"
    assert RunStateView.status(:ended_by_operator) == "pending"
  end

  test "feature status atoms use status_class/1" do
    assert RunStateView.status(:escalated) == "escalated"
    assert RunStateView.status(:never_started) == "blocked"
    assert RunStateView.status(:done) == "done"
  end

  test "unknown terms map to pending and never raise" do
    for term <- [:nope, nil, "x", 1, {:a, :b}, %{}],
        do: assert(RunStateView.status(term) == "pending")
  end

  test "every mapped status is a contract status" do
    for s <- [
          :in_flight,
          :completed,
          :parked,
          :superseded,
          :interrupted,
          :ended_by_operator,
          :zzz
        ],
        do: assert(RunStateView.status(s) in CoreComponents.statuses())
  end

  test "label/1 is the real atom text" do
    assert RunStateView.label(:in_flight) == ":in_flight"
    assert RunStateView.label(nil) == "—"
    assert RunStateView.label("mixed") == "mixed"
  end

  test "status_counts/1 omits zeros and follows statuses/0 order" do
    counts =
      RunStateView.status_counts(%{
        "001" => :done,
        "002" => :running,
        "003" => :done,
        "004" => :pending
      })

    assert counts == [{"done", 2}, {"running", 1}, {"pending", 1}]
    assert RunStateView.status_counts(%{}) == []
    assert RunStateView.status_counts(nil) == []
  end
end
