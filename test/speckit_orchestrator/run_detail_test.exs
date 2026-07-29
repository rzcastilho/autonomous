defmodule SpeckitOrchestrator.RunDetailTest do
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Config, RepoIdentity}

  defp repo_id, do: RepoIdentity.partition(Config.repo())

  defp open(feature_ids, opts \\ []) do
    features =
      Enum.map(feature_ids, fn id ->
        %{
          feature_id: id,
          slug: "f-#{id}",
          path: "specs/#{id}",
          number: String.to_integer(id),
          group: :backlog,
          created_at: nil
        }
      end)

    {:ok, run_id} =
      Writer.open_run(repo_id(), %{
        features: features,
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    if outcome = Keyword.get(opts, :close),
      do: :ok = Writer.close_run({repo_id(), run_id}, outcome, [])

    run_id
  end

  defp record_attempt(run_id, feature_id, phase, ordinal, overrides \\ %{}) do
    attempt =
      Map.merge(
        %{
          feature_id: feature_id,
          phase: phase,
          ordinal: ordinal,
          step: Map.get(overrides, :step, ordinal),
          label: "#{phase}-#{ordinal}",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 10,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.1,
          cost_kind: :actual
        },
        overrides
      )

    :ok =
      Writer.record_phase_attempt({repo_id(), run_id}, %{
        attempt: attempt,
        cost: %{amount_usd: attempt.cost_usd, kind: attempt.cost_kind},
        checkpoint: %{phase: phase, last_completed_phase: phase, status: :in_progress},
        transcript: "transcript for #{phase} ##{ordinal}"
      })
  end

  test "phase sequence in execution order with outcome/model/cost/duration (US3 acceptance 1)" do
    run_id = open(["001"])
    record_attempt(run_id, "001", :specify, 1, %{step: 1})
    record_attempt(run_id, "001", :clarify, 1, %{step: 2})

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    [feature] = detail.features

    assert Enum.map(feature.phase_attempts, & &1.phase) == [:specify, :clarify]
    [first | _] = feature.phase_attempts
    assert first.outcome == :ok
    assert first.model == "sonnet"
    assert first.cost_usd == 0.1
    assert first.duration_ms == 10
  end

  test "each phase attempt carries a transcript_ref, not the body (FR-036, SC-009)" do
    run_id = open(["001"])
    record_attempt(run_id, "001", :specify, 1)

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    [feature] = detail.features
    [attempt] = feature.phase_attempts

    assert attempt.transcript_ref == {repo_id(), run_id, "001", :specify, 1}
    refute Map.has_key?(attempt, :body)
    refute attempt |> Map.values() |> Enum.any?(&(&1 == "transcript for specify #1"))
  end

  test "escalation reason, originating phase, and triggering evidence (US3 acceptance 2)" do
    run_id = open(["001"])

    :ok =
      Writer.record_escalation({repo_id(), run_id}, %{
        feature_id: "001",
        kind: :escalated,
        phase: :analyze,
        severity: :high,
        reason: "critical finding",
        evidence: %{findings: [%{severity: :critical}]}
      })

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    [feature] = detail.features
    [escalation] = feature.escalations

    assert escalation.phase == :analyze
    assert escalation.severity == :high
    assert escalation.reason == "critical finding"
    assert escalation.evidence == %{findings: [%{severity: :critical}]}
    assert escalation.resolution == nil
  end

  test "transcript retrievable via transcript/1 after the attempt is recorded (US3 acceptance 3, SC-006)" do
    run_id = open(["001"])
    record_attempt(run_id, "001", :implement, 1)

    attempt_id = {repo_id(), run_id, "001", :implement, 1}

    assert {:ok, %{body: "transcript for implement #1"}} =
             SpeckitOrchestrator.transcript(attempt_id)
  end

  test "each remediation attempt individually listed with limit/threshold in force (US3 acceptance 4)" do
    run_id = open(["001"])

    :ok =
      Writer.record_remediation_attempt({repo_id(), run_id}, %{
        remediation: %{
          feature_id: "001",
          ordinal: 1,
          findings: [%{severity: :high}],
          max_severity: :high,
          outcome: :ok,
          cost_usd: 0.3,
          attempt_limit: 2,
          threshold: :high,
          model: "opus"
        },
        phase_attempt: %{
          step: 3,
          label: "remediation",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 100,
          outcome: :ok,
          model: "opus",
          cost_usd: 0.3,
          cost_kind: :actual
        },
        cost: %{amount_usd: 0.3, kind: :actual},
        transcript: "remediation output"
      })

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    [feature] = detail.features
    [remediation] = feature.remediation_attempts

    assert remediation.ordinal == 1
    assert remediation.attempt_limit == 2
    assert remediation.threshold == :high
    assert remediation.max_severity == :high
  end

  test "amendments with their effective point (FR-027)" do
    run_id = open(["001"])
    run_key = {repo_id(), run_id}

    :ok = Writer.record_settings_amendment(run_key, %{max_concurrency: [2, 3]}, nil)

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    [amendment] = detail.amendments

    assert amendment.changes == %{max_concurrency: [2, 3]}
    assert amendment.effective_after == nil
  end

  test "resolve_escalation/2 records a resolution and never deletes the entry (FR-026)" do
    run_id = open(["001"])

    :ok =
      Writer.record_escalation({repo_id(), run_id}, %{
        feature_id: "001",
        kind: :escalated,
        phase: :clarify,
        reason: "needs human",
        evidence: %{}
      })

    escalation_id = {repo_id(), run_id, "001", 1}
    assert :ok = SpeckitOrchestrator.resolve_escalation(escalation_id, note: "reviewed")

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    [feature] = detail.features
    [escalation] = feature.escalations

    assert escalation.resolution.note == "reviewed"
    assert %DateTime{} = escalation.resolution.resolved_at
  end

  test "run_detail includes settings and checkpoint" do
    run_id = open(["001"])
    record_attempt(run_id, "001", :specify, 1)

    {:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
    assert detail.settings == %{max_concurrency: 2}
    [feature] = detail.features
    assert feature.checkpoint.phase == :specify
  end

  test "absent run returns {:error, :absent}" do
    assert {:error, :absent} = SpeckitOrchestrator.run_detail("r999999")
  end
end
