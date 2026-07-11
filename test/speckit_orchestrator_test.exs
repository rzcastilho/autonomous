defmodule SpeckitOrchestratorTest do
  # async: false — starts a named Coordinator via the facade.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Feature

  test "run/1 with an injected runner drives the backlog to completion; status/0 reflects it" do
    features = [
      %Feature{id: "001", slug: "a", path: "a.md"},
      %Feature{id: "002", slug: "b", path: "b.md", prereqs: ["001"]}
    ]

    fake = fn feature, notify -> notify.(feature.id, :done, nil) end

    {:ok, pid} = SpeckitOrchestrator.run(features: features, runner: fake, owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002"]
    assert SpeckitOrchestrator.status().finished?
  end
end
