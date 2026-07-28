defmodule SpeckitOrchestrator.Store.RecordsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Records

  alias SpeckitOrchestrator.Store.Records.{
    CostEntry,
    Checkpoint,
    Escalation,
    FeatureRun,
    Meta,
    PhaseAttempt,
    RemediationAttempt,
    Run,
    RunSettings,
    Seq,
    SettingsAmendment,
    Transcript
  }

  @now DateTime.utc_now()

  @fixtures %{
    speckit_meta: %Meta{key: :schema_version, value: 1},
    speckit_seq: %Seq{
      repo_id: "o:repo-abc",
      next_seq: 3,
      origin: "github.com/x/y",
      local_path: "/tmp/x"
    },
    speckit_run: %Run{
      key: {"o:repo-abc", "r000001"},
      repo_id: "o:repo-abc",
      run_id: "r000001",
      state: :in_flight,
      outcome: nil,
      outcome_index: :in_flight,
      started_at: @now,
      ended_at: nil,
      duration_ms: nil,
      spend_usd: 0.0,
      record_complete?: true,
      halt_reason: nil,
      scope: :ad_hoc,
      layout: %{},
      superseded_by: nil,
      schema_version: 1
    },
    speckit_run_settings: %RunSettings{
      run_key: {"o:repo-abc", "r000001"},
      settings: %{max_concurrency: 2},
      captured_at: @now
    },
    speckit_settings_amendment: %SettingsAmendment{
      id: {"o:repo-abc", "r000001", 1},
      run_key: {"o:repo-abc", "r000001"},
      ordinal: 1,
      changes: %{max_concurrency: [2, 3]},
      effective_at: @now,
      effective_after: {"o:repo-abc", "r000001", "003", :analyze, 1}
    },
    speckit_feature_run: %FeatureRun{
      key: {"o:repo-abc", "r000001", "003"},
      run_key: {"o:repo-abc", "r000001"},
      feature_id: "003",
      slug: "ledger-entries",
      path: "specs/autonomous/003-ledger-entries",
      prereqs: ["001"],
      status: :pending,
      terminal_reason: nil,
      worktree_path: nil,
      branch: nil,
      pr_description: nil,
      started_at: nil,
      ended_at: nil
    },
    speckit_phase_attempt: %PhaseAttempt{
      attempt_id: {"o:repo-abc", "r000001", "003", :analyze, 1},
      run_key: {"o:repo-abc", "r000001"},
      feature_key: {"o:repo-abc", "r000001", "003"},
      phase: :analyze,
      ordinal: 1,
      step: 5,
      label: "analyze",
      started_at: @now,
      ended_at: @now,
      duration_ms: 1234,
      outcome: :ok,
      model: "opus",
      cost_usd: 0.41,
      cost_kind: :actual,
      substep: nil,
      session_id: "sess-1",
      error: nil
    },
    speckit_checkpoint: %Checkpoint{
      key: {"o:repo-abc", "r000001", "003"},
      run_key: {"o:repo-abc", "r000001"},
      phase: :analyze,
      last_completed_phase: :tasks,
      status: :in_progress,
      reason: nil,
      session_id: "sess-1",
      implement_chunk: nil,
      analyze_remediation: %{attempts_used: 1, limit: 2},
      updated_at: @now
    },
    speckit_escalation: %Escalation{
      id: {"o:repo-abc", "r000001", "003", 1},
      run_key: {"o:repo-abc", "r000001"},
      feature_id: "003",
      kind: :escalated,
      phase: :analyze,
      severity: :high,
      reason: "High finding",
      evidence: %{findings: []},
      raised_at: @now,
      resolution: nil
    },
    speckit_remediation_attempt: %RemediationAttempt{
      id: {"o:repo-abc", "r000001", "003", 1},
      run_key: {"o:repo-abc", "r000001"},
      feature_key: {"o:repo-abc", "r000001", "003"},
      ordinal: 1,
      findings: [],
      max_severity: :high,
      outcome: :ok,
      cost_usd: 0.28,
      attempt_limit: 2,
      threshold: :high,
      model: "opus",
      attempt_id: {"o:repo-abc", "r000001", "003", :remediation, 1}
    },
    speckit_cost_entry: %CostEntry{
      id: {"o:repo-abc", "r000001", "003", :analyze, 1},
      run_key: {"o:repo-abc", "r000001"},
      amount_usd: 0.41,
      kind: :actual,
      recorded_at: @now
    },
    speckit_transcript: %Transcript{
      attempt_id: {"o:repo-abc", "r000001", "003", :analyze, 1},
      body: <<"raw output", 0xFF>>,
      bytes: 11,
      written_at: @now
    }
  }

  describe "encode/1 + decode/2 round trip" do
    for {table, fixture} <- @fixtures do
      test "#{table}" do
        table = unquote(table)
        fixture = unquote(Macro.escape(fixture))

        tuple = Records.encode(fixture)
        assert elem(tuple, 0) == table
        assert {:ok, ^fixture} = Records.decode(table, tuple)
      end
    end
  end

  describe "damaged-row reporting" do
    test "wrong arity is reported as damaged, never coerced" do
      assert {:error, {:damaged, "o:repo-abc", :shape_mismatch}} =
               Records.decode(:speckit_seq, {:speckit_seq, "o:repo-abc", 1})
    end

    test "wrong record name is reported as damaged" do
      assert {:error, {:damaged, key, :shape_mismatch}} =
               Records.decode(:speckit_seq, {:not_speckit_seq, "o:repo-abc", 1, nil, nil})

      assert key == "o:repo-abc"
    end

    test "unknown table is reported as damaged" do
      assert {:error, {:damaged, :unknown, :shape_mismatch}} =
               Records.decode(:not_a_real_table, {:not_a_real_table})
    end

    test "damaged key falls back to :unknown on a too-small tuple" do
      assert {:error, {:damaged, :unknown, :shape_mismatch}} =
               Records.decode(:speckit_meta, {:speckit_meta})
    end
  end

  describe "table_for/1" do
    test "maps a struct back to its table name" do
      assert Records.table_for(%Run{}) == :speckit_run
      assert Records.table_for(%Transcript{}) == :speckit_transcript
    end
  end
end
