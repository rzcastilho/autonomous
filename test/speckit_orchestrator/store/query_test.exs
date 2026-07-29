defmodule SpeckitOrchestrator.Store.QueryTest do
  use SpeckitOrchestrator.StoreCase, async: false

  @repo "o:query-test"

  defp open(repo, feature_ids) do
    features =
      Enum.map(feature_ids, &%{feature_id: &1, slug: "f-#{&1}", path: "specs/#{&1}", prereqs: []})

    {:ok, run_id} =
      Writer.open_run(repo, %{
        features: features,
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    {repo, run_id}
  end

  describe "runs/2" do
    test "most recent first (FR-021)" do
      repo = "o:query-order"
      {_repo, run_1} = open(repo, ["001"])
      {_repo, run_2} = open(repo, ["001"])
      {_repo, run_3} = open(repo, ["001"])

      {:ok, summaries} = Query.runs(repo)
      assert Enum.map(summaries, & &1.run_id) == [run_3, run_2, run_1]
    end

    test "an unknown repository returns {:ok, []}, not an error (US2 acceptance 4)" do
      assert {:ok, []} = Query.runs("o:never-seen")
    end

    test "filters by outcome" do
      repo = "o:query-outcome"
      {_repo, run_1} = open(repo, ["001"])
      {_repo, run_2} = open(repo, ["001"])

      Writer.close_run({repo, run_1}, :all_done, [])
      Writer.close_run({repo, run_2}, :halted, [])

      {:ok, halted} = Query.runs(repo, outcome: :halted)
      assert Enum.map(halted, & &1.run_id) == [run_2]

      {:ok, both} = Query.runs(repo, outcome: [:all_done, :halted])
      assert length(both) == 2
    end

    test "filters by feature (every run in which feature X appears)" do
      repo = "o:query-feature"
      {_repo, run_1} = open(repo, ["001", "002"])
      {_repo, _run_2} = open(repo, ["003"])

      {:ok, results} = Query.runs(repo, feature: "002")
      assert Enum.map(results, & &1.run_id) == [run_1]
    end

    test "limit caps the result count, before pages older than a run_id" do
      repo = "o:query-limit"
      {_repo, run_1} = open(repo, ["001"])
      {_repo, run_2} = open(repo, ["001"])
      {_repo, _run_3} = open(repo, ["001"])

      {:ok, limited} = Query.runs(repo, limit: 2)
      assert length(limited) == 2

      {:ok, before} = Query.runs(repo, before: run_2)
      assert Enum.map(before, & &1.run_id) == [run_1]
    end

    test "starting a new run destroys 0 prior records (SC-004) — superseded run retained and distinguishable" do
      repo = "o:query-supersede"
      {_repo, run_1} = open(repo, ["001"])
      {_repo, run_2} = open(repo, ["001"])

      {:ok, summaries} = Query.runs(repo)
      assert length(summaries) == 2

      superseded = Enum.find(summaries, &(&1.run_id == run_1))
      assert superseded.superseded_by == run_2
    end

    # Mnesia enforces a table's record arity on write, so a genuinely
    # malformed row can't be injected through a live write — decode's
    # damaged-row reporting (FR-008, SC-011) is covered exhaustively at the
    # unit level in `store/records_test.exs`.
  end

  describe "run/1" do
    test "returns every feature's phase_attempts, escalations, remediation_attempts, checkpoint" do
      {repo, run_id} = open(@repo, ["001"])
      run_key = {repo, run_id}

      Writer.record_phase_attempt(run_key, %{
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
          cost_usd: 0.1,
          cost_kind: :actual
        },
        cost: %{amount_usd: 0.1, kind: :actual},
        checkpoint: %{phase: :clarify, last_completed_phase: :specify, status: :in_progress}
      })

      Writer.record_escalation(run_key, %{
        feature_id: "001",
        kind: :escalated,
        phase: :clarify,
        reason: "needs human",
        evidence: %{}
      })

      {:ok, detail} = Query.run(run_key)

      assert detail.run.run_id == run_id
      assert detail.settings == %{max_concurrency: 2}
      assert length(detail.cost_entries) == 1

      [feature] = detail.features
      assert feature.feature_id == "001"
      assert length(feature.phase_attempts) == 1
      assert length(feature.escalations) == 1
      assert feature.checkpoint.phase == :clarify
    end

    test "absent run returns {:error, :absent}" do
      assert {:error, :absent} = Query.run({"o:query-absent", "r999999"})
    end

    test "a complete run returns {:ok, detail} — distinct from absent and damaged" do
      {repo, run_id} = open(@repo, ["001"])
      assert {:ok, %{run: %{run_id: ^run_id}}} = Query.run({repo, run_id})
    end
  end

  describe "checkpoint/2" do
    test "returns the feature's checkpoint" do
      {repo, run_id} = open(@repo, ["001"])
      run_key = {repo, run_id}

      Writer.record_phase_attempt(run_key, %{
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
        checkpoint: %{phase: :clarify, last_completed_phase: :specify, status: :in_progress}
      })

      assert {:ok, checkpoint} = Query.checkpoint(run_key, "001")
      assert checkpoint.phase == :clarify
    end

    test "absent when the feature has none" do
      {repo, run_id} = open(@repo, ["001"])
      assert {:error, :absent} = Query.checkpoint({repo, run_id}, "001")
    end
  end

  describe "transcript/1" do
    test "on-demand retrieval, verbatim" do
      {repo, run_id} = open(@repo, ["001"])
      run_key = {repo, run_id}

      Writer.record_phase_attempt(run_key, %{
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
        transcript: "the exact output"
      })

      attempt_id = {repo, run_id, "001", :specify, 1}
      assert {:ok, %{body: "the exact output"}} = Query.transcript(attempt_id)
    end

    test "absent when no transcript was recorded" do
      assert {:error, :absent} = Query.transcript({"x", "r000001", "001", :specify, 1})
    end
  end

  describe "in_flight_run/1" do
    test "returns the sole in-flight run for a repo" do
      {repo, run_id} = open("o:query-inflight", ["001"])
      assert {:ok, %{run_id: ^run_id}} = Query.in_flight_run(repo)
    end

    test ":none once the run is closed" do
      {repo, run_id} = open("o:query-inflight-closed", ["001"])
      Writer.close_run({repo, run_id}, :all_done, [])
      assert Query.in_flight_run(repo) == :none
    end

    test ":none for a repo with no runs" do
      assert Query.in_flight_run("o:query-never-seen") == :none
    end
  end

  describe "capacity/0" do
    test "reports non-negative used_bytes and transcript_bytes" do
      capacity = Query.capacity()
      assert capacity.used_bytes >= 0
      assert capacity.transcript_bytes >= 0
    end
  end
end
