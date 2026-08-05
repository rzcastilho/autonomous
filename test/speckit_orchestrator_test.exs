defmodule SpeckitOrchestratorTest do
  # async: false — starts a named Coordinator via the facade. StoreCase (not
  # plain ExUnit.Case) because `run/1`'s preflight refuses
  # `{:parked_run, …}` for a repository that already has one, and the store is
  # node-global: any earlier test in the suite that parked a run (several
  # console and store tests do) made this one fail on a repository it never
  # touched. Clearing the tables first is exactly what StoreCase exists for.
  use SpeckitOrchestrator.StoreCase, async: false
  import ExUnit.CaptureIO

  alias SpeckitOrchestrator.Feature

  test "run/1 with an injected runner drives the backlog to completion; status/0 reflects it" do
    features = [
      %Feature{id: "001", number: 1, slug: "a", path: "a.md"},
      %Feature{id: "002", number: 2, slug: "b", path: "b.md"}
    ]

    fake = fn feature, notify -> notify.(feature.id, :done, nil) end

    {:ok, pid} = SpeckitOrchestrator.run(features: features, runner: fake, owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002"]
    assert SpeckitOrchestrator.status().finished?

    out = capture_io(fn -> SpeckitOrchestrator.print_status() end)
    assert out =~ "FEATURE"
    assert out =~ "001"
  end
end
