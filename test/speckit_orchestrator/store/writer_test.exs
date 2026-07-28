defmodule SpeckitOrchestrator.Store.WriterTest do
  use SpeckitOrchestrator.StoreCase, async: false

  @repo "o:writer-test"

  defp features(ids) do
    Enum.map(ids, fn id ->
      %{feature_id: id, slug: "feature-#{id}", path: "specs/#{id}", prereqs: []}
    end)
  end

  defp open(repo \\ @repo, feature_ids \\ ["001"]) do
    {:ok, run_id} =
      Writer.open_run(repo, %{
        features: features(feature_ids),
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    {repo, run_id}
  end

  defp read_run(run_key) do
    {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_run, run_key) end)
    {:ok, run} = Records.decode(:speckit_run, tuple)
    run
  end

  defp read_feature(feature_key) do
    {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_feature_run, feature_key) end)
    {:ok, feature} = Records.decode(:speckit_feature_run, tuple)
    feature
  end

  describe "open_run/2" do
    test "writes the run, run_settings, and every feature_run row in one transaction" do
      {repo, run_id} = open(@repo, ["001", "002"])
      run_key = {repo, run_id}

      run = read_run(run_key)
      assert run.state == :in_flight
      assert run.repo_id == repo

      {:ok, [settings_tuple]} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_run_settings, run_key) end)

      assert {:ok, %Records.RunSettings{settings: %{max_concurrency: 2}}} =
               Records.decode(:speckit_run_settings, settings_tuple)

      assert read_feature({repo, run_id, "001"}).status == :pending
      assert read_feature({repo, run_id, "002"}).status == :pending
    end

    test "run_id is a stable, zero-padded, per-repository sequence" do
      {_repo, run_id_1} = open("o:writer-seq", ["001"])
      {_repo, run_id_2} = open("o:writer-seq", ["001"])

      assert run_id_1 == "r000001"
      assert run_id_2 == "r000002"
    end

    test "starting a new run supersedes the prior in-flight run and its non-terminal features" do
      {repo, run_id_1} = open("o:writer-supersede", ["001", "002"])

      Writer.record_feature_terminal({repo, run_id_1}, "001", :done, nil)

      {_repo, run_id_2} = open("o:writer-supersede", ["003"])

      prior = read_run({repo, run_id_1})
      assert prior.state == :superseded
      assert prior.superseded_by == run_id_2

      # already-:done feature is untouched by the supersession
      assert read_feature({repo, run_id_1, "001"}).status == :done
      # the still-:pending feature is marked ended_by_supersession
      assert read_feature({repo, run_id_1, "002"}).status == :ended_by_supersession
    end

    test "N concurrent open_run/2 calls for the same repo leave exactly one :in_flight row (FR-034, SC-012)" do
      repo = "o:writer-concurrent-open"

      1..12
      |> Task.async_stream(fn _ -> open(repo, ["001"]) end, max_concurrency: 12)
      |> Stream.run()

      {:ok, rows} = Mnesia.transaction(fn -> Mnesia.index_read(:speckit_run, repo, :repo_id) end)
      in_flight = Enum.filter(rows, fn tuple -> elem(tuple, 4) == :in_flight end)

      assert length(rows) == 12
      assert length(in_flight) == 1
    end
  end

  describe "record_phase_attempt/2" do
    test "writes attempt + cost_entry + checkpoint + transcript in one transaction" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      assert :ok =
               Writer.record_phase_attempt(run_key, %{
                 attempt: %{
                   feature_id: "001",
                   phase: :specify,
                   ordinal: 1,
                   step: 1,
                   label: "specify",
                   started_at: DateTime.utc_now(),
                   ended_at: DateTime.utc_now(),
                   duration_ms: 100,
                   outcome: :ok,
                   model: "sonnet",
                   cost_usd: 0.2,
                   cost_kind: :actual
                 },
                 cost: %{amount_usd: 0.2, kind: :actual},
                 checkpoint: %{
                   phase: :clarify,
                   last_completed_phase: :specify,
                   status: :in_progress
                 },
                 transcript: "specify output"
               })

      attempt_id = {repo, run_id, "001", :specify, 1}

      {:ok, attempt_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_phase_attempt, attempt_id) end)

      assert length(attempt_rows) == 1

      {:ok, cost_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_cost_entry, attempt_id) end)

      assert length(cost_rows) == 1

      {:ok, checkpoint_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_checkpoint, {repo, run_id, "001"}) end)

      assert length(checkpoint_rows) == 1

      {:ok, transcript_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_transcript, attempt_id) end)

      assert [{:speckit_transcript, ^attempt_id, "specify output", 14, _}] = transcript_rows
    end

    test "omitting cost/checkpoint/transcript writes only the phase_attempt row" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: %{
            feature_id: "001",
            phase: :specify,
            ordinal: 1,
            step: 1,
            label: "specify",
            started_at: DateTime.utc_now(),
            ended_at: DateTime.utc_now(),
            duration_ms: 100,
            outcome: :ok,
            model: "sonnet",
            cost_usd: 0.0,
            cost_kind: :estimate
          }
        })

      attempt_id = {repo, run_id, "001", :specify, 1}

      {:ok, cost_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_cost_entry, attempt_id) end)

      {:ok, checkpoint_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_checkpoint, {repo, run_id, "001"}) end)

      {:ok, transcript_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_transcript, attempt_id) end)

      assert cost_rows == []
      assert checkpoint_rows == []
      assert transcript_rows == []
    end

    test "a checkpoint write supersedes the feature's prior checkpoint in place" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      feature_key = {repo, run_id, "001"}

      base_attempt = %{
        feature_id: "001",
        step: 1,
        label: "x",
        started_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now(),
        duration_ms: 1,
        outcome: :ok,
        model: "sonnet",
        cost_usd: 0.0,
        cost_kind: :estimate
      }

      Writer.record_phase_attempt(run_key, %{
        attempt: Map.merge(base_attempt, %{phase: :specify, ordinal: 1}),
        checkpoint: %{phase: :clarify, last_completed_phase: :specify, status: :in_progress}
      })

      Writer.record_phase_attempt(run_key, %{
        attempt: Map.merge(base_attempt, %{phase: :clarify, ordinal: 1}),
        checkpoint: %{phase: :plan, last_completed_phase: :clarify, status: :in_progress}
      })

      {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_checkpoint, feature_key) end)
      {:ok, checkpoint} = Records.decode(:speckit_checkpoint, tuple)
      assert checkpoint.phase == :plan
      assert checkpoint.last_completed_phase == :clarify
    end

    test "parallel writers to disjoint feature keys lose no update (FR-007, SC-008)" do
      feature_ids = for n <- 1..20, do: String.pad_leading(Integer.to_string(n), 3, "0")
      {repo, run_id} = open(@repo, feature_ids)
      run_key = {repo, run_id}

      feature_ids
      |> Task.async_stream(
        fn feature_id ->
          Writer.record_phase_attempt(run_key, %{
            attempt: %{
              feature_id: feature_id,
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
            }
          })
        end,
        max_concurrency: 20
      )
      |> Enum.each(fn {:ok, :ok} -> :ok end)

      {:ok, rows} =
        Mnesia.transaction(fn -> Mnesia.index_read(:speckit_phase_attempt, run_key, :run_key) end)

      assert length(rows) == 20
    end
  end

  describe "record_remediation_attempt/2" do
    test "writes the corrective phase_attempt, remediation_attempt, cost_entry, and transcript" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      :ok =
        Writer.record_remediation_attempt(run_key, %{
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

      attempt_id = {repo, run_id, "001", :auto_remediation, 1}

      {:ok, [pa]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_phase_attempt, attempt_id) end)

      assert {:ok, %Records.PhaseAttempt{phase: :auto_remediation}} =
               Records.decode(:speckit_phase_attempt, pa)

      {:ok, [ra]} =
        Mnesia.transaction(fn ->
          Mnesia.read(:speckit_remediation_attempt, {repo, run_id, "001", 1})
        end)

      assert {:ok, %Records.RemediationAttempt{attempt_id: ^attempt_id}} =
               Records.decode(:speckit_remediation_attempt, ra)

      {:ok, [_cost]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_cost_entry, attempt_id) end)

      {:ok, [_transcript]} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_transcript, attempt_id) end)
    end
  end

  describe "record_feature_terminal/4" do
    test "updates status/terminal_reason/ended_at and deletes the checkpoint on :done" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      feature_key = {repo, run_id, "001"}

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
        checkpoint: %{phase: :converge, last_completed_phase: :implement, status: :in_progress}
      })

      assert :ok = Writer.record_feature_terminal(run_key, "001", :done, nil)

      feature = read_feature(feature_key)
      assert feature.status == :done
      assert feature.ended_at != nil

      {:ok, checkpoint_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_checkpoint, feature_key) end)

      assert checkpoint_rows == []
    end

    test "opts[:pr_description] is written in the same transaction (018, FR-037 — replaces Describe.write_pr/3)" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      feature_key = {repo, run_id, "001"}

      pr = %{pr_title: "Add x", pr_body: "## Summary\n- x"}
      assert :ok = Writer.record_feature_terminal(run_key, "001", :done, nil, pr_description: pr)

      assert read_feature(feature_key).pr_description == pr
    end

    test "a non-:done terminal leaves the checkpoint in place" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      feature_key = {repo, run_id, "001"}

      Writer.record_phase_attempt(run_key, %{
        attempt: %{
          feature_id: "001",
          phase: :analyze,
          ordinal: 1,
          step: 1,
          label: "analyze",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 1,
          outcome: :ok,
          model: "opus",
          cost_usd: 0.0,
          cost_kind: :estimate
        },
        checkpoint: %{phase: :analyze, last_completed_phase: :tasks, status: :escalated}
      })

      Writer.record_feature_terminal(run_key, "001", :escalated, "High finding")

      {:ok, checkpoint_rows} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_checkpoint, feature_key) end)

      assert length(checkpoint_rows) == 1
    end

    test "an unknown feature aborts the transaction and reports to Store.Health" do
      {repo, run_id} = open()
      refute Health.failed?()

      assert {:error, {:absent, _}} =
               Writer.record_feature_terminal({repo, run_id}, "nope", :done, nil)

      assert Health.failed?()
      assert {:failed, {:absent, _}, %DateTime{}} = Health.status()
      # Store.Health is a single named process shared by the whole test run,
      # not reset by StoreCase's per-test setup after THIS test — a poisoned
      # flag left here would fail every later run/1 call anywhere in the
      # suite (mirrors persistence_failure_test.exs's own safeguard).
      Health.clear()
    end
  end

  describe "record_escalation/2 + resolve_escalation/2" do
    test "escalations for the same feature get sequential ordinals" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      escalation = %{
        feature_id: "001",
        kind: :escalated,
        phase: :analyze,
        reason: "r1",
        evidence: %{}
      }

      :ok = Writer.record_escalation(run_key, escalation)
      :ok = Writer.record_escalation(run_key, Map.put(escalation, :reason, "r2"))

      {:ok, rows} =
        Mnesia.transaction(fn -> Mnesia.index_read(:speckit_escalation, run_key, :run_key) end)

      assert length(rows) == 2

      ordinals = Enum.map(rows, &elem(&1, 1)) |> Enum.map(&elem(&1, 3)) |> Enum.sort()
      assert ordinals == [1, 2]
    end

    test "resolving sets resolution and never deletes the row" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      :ok =
        Writer.record_escalation(run_key, %{
          feature_id: "001",
          kind: :escalated,
          phase: :analyze,
          reason: "r1",
          evidence: %{}
        })

      escalation_id = {repo, run_id, "001", 1}

      assert :ok =
               Writer.resolve_escalation(escalation_id, %{
                 resolved_at: DateTime.utc_now(),
                 note: "fixed"
               })

      {:ok, [tuple]} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_escalation, escalation_id) end)

      {:ok, escalation} = Records.decode(:speckit_escalation, tuple)
      assert escalation.resolution.note == "fixed"
    end

    test "resolving an unknown escalation aborts and reports to Store.Health" do
      assert {:error, {:absent, _}} = Writer.resolve_escalation({"x", "r000001", "001", 1}, %{})
      assert Health.failed?()
      # See the note in the test above — clean up the shared Health process.
      Health.clear()
    end
  end

  describe "record_settings_amendment/3" do
    test "amendments for the same run get sequential ordinals" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      :ok =
        Writer.record_settings_amendment(
          run_key,
          %{max_concurrency: [2, 3]},
          {repo, run_id, "001", :analyze, 1}
        )

      :ok = Writer.record_settings_amendment(run_key, %{budget_usd: [25.0, 40.0]}, nil)

      {:ok, rows} =
        Mnesia.transaction(fn ->
          Mnesia.index_read(:speckit_settings_amendment, run_key, :run_key)
        end)

      assert length(rows) == 2
    end
  end

  describe "close_run/3" do
    test "sets state completed, outcome, ended_at, and duration_ms" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      assert :ok = Writer.close_run(run_key, :all_done, spend_usd: 3.5)

      run = read_run(run_key)
      assert run.state == :completed
      assert run.outcome == :all_done
      assert run.outcome_index == :all_done
      assert run.spend_usd == 3.5
      assert run.ended_at != nil
      assert is_integer(run.duration_ms)
    end
  end

  describe "flag_record_incomplete/2" do
    test "sets record_complete? false and the halt_reason, leaving state untouched" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      assert :ok = Writer.flag_record_incomplete(run_key, {:persistence_failed, :write_timeout})

      run = read_run(run_key)
      assert run.record_complete? == false
      assert run.halt_reason == {:persistence_failed, :write_timeout}
      assert run.state == :in_flight
    end
  end
end
