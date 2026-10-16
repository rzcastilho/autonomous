defmodule Autonomous.Web.PackViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.PackView

  test "state/1 maps a supplied pack" do
    assert PackView.state({:ok, %{source: :supplied, contract: 6}}) == {:supplied, 6}
  end

  test "state/1 maps a committed pack with its contract" do
    assert PackView.state({:ok, %{source: :committed, contract: 7}}) == {:committed, 7}
  end

  test "state/1 renders a refusal through Report.format_reason/1, never inspect/1" do
    assert {:refused, text} =
             PackView.state({:error, {:pack_outdated, ".claude/autonomous-pack.json", "fix it"}})

    assert text == ".claude/autonomous-pack.json: fix it"
    refute text =~ "{:"
  end

  test "summary/1 strings" do
    assert PackView.summary({:supplied, 6}) == "supplied by the orchestrator — contract 6"
    assert PackView.summary({:committed, 6}) == "committed in the target — contract 6"
    assert PackView.summary({:refused, "because"}) == "because"
  end

  test "source_name/1 is a name only" do
    assert PackView.source_name({:supplied, 6}) == "supplied"
    assert PackView.source_name({:committed, 6}) == "committed"
    assert PackView.source_name({:refused, "x"}) == "refused"
  end
end
