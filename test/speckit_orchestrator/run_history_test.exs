defmodule SpeckitOrchestrator.RunHistoryTest do
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Config, RepoIdentity}

  defp repo_id, do: RepoIdentity.partition(Config.repo())

  defp open(feature_ids, opts \\ []) do
    features =
      Enum.map(feature_ids, &%{feature_id: &1, slug: "f-#{&1}", path: "specs/#{&1}", prereqs: []})

    {:ok, run_id} =
      Writer.open_run(repo_id(), %{
        features: features,
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    if outcome = Keyword.get(opts, :close) do
      :ok = Writer.close_run({repo_id(), run_id}, outcome, [])
    end

    run_id
  end

  test "most recent first (FR-021)" do
    run_1 = open(["001"])
    run_2 = open(["001"])

    {:ok, runs} = SpeckitOrchestrator.run_history()
    assert Enum.map(runs, & &1.run_id) == [run_2, run_1]
  end

  test "starting a new run destroys 0 prior records (SC-004) — superseded run retained and distinguishable (FR-023)" do
    run_1 = open(["001"])
    run_2 = open(["001"])

    {:ok, runs} = SpeckitOrchestrator.run_history()
    assert length(runs) == 2

    superseded = Enum.find(runs, &(&1.run_id == run_1))
    assert superseded.superseded_by == run_2
  end

  test "outcome filter, atom or list (FR-024)" do
    run_1 = open(["001"], close: :all_done)
    run_2 = open(["001"], close: :halted)

    {:ok, halted} = SpeckitOrchestrator.run_history(outcome: :halted)
    assert Enum.map(halted, & &1.run_id) == [run_2]

    {:ok, both} = SpeckitOrchestrator.run_history(outcome: [:all_done, :halted])
    assert length(both) == 2
    refute Enum.any?(both, &(&1.run_id not in [run_1, run_2]))
  end

  test "feature filter — every run in which the feature appears (FR-024)" do
    run_1 = open(["001", "002"])
    _run_2 = open(["003"])

    {:ok, runs} = SpeckitOrchestrator.run_history(feature: "002")
    assert Enum.map(runs, & &1.run_id) == [run_1]
  end

  test "limit caps the result count, before pages older than a run_id" do
    run_1 = open(["001"])
    run_2 = open(["001"])
    _run_3 = open(["001"])

    {:ok, limited} = SpeckitOrchestrator.run_history(limit: 2)
    assert length(limited) == 2

    {:ok, before} = SpeckitOrchestrator.run_history(before: run_2)
    assert Enum.map(before, & &1.run_id) == [run_1]
  end

  test "an unknown repository returns {:ok, []}, not an error (US2 acceptance 4)" do
    unknown_repo =
      Path.join(System.tmp_dir!(), "run-history-unknown-#{System.unique_integer([:positive])}")

    assert {:ok, []} = SpeckitOrchestrator.run_history(repo: unknown_repo)
  end

  test "never loads transcript content (FR-036, SC-009)" do
    run_id = open(["001"])

    :ok =
      Writer.record_phase_attempt({repo_id(), run_id}, %{
        attempt: %{
          feature_id: "001",
          phase: :specify,
          ordinal: 1,
          step: 1,
          label: "specify",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 1,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.0,
          cost_kind: :estimate
        },
        transcript: "the exact transcript body"
      })

    {:ok, runs} = SpeckitOrchestrator.run_history()
    run = Enum.find(runs, &(&1.run_id == run_id))

    refute Map.has_key?(run, :transcript)
    refute run |> Map.values() |> Enum.any?(&(&1 == "the exact transcript body"))
  end
end
