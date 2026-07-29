defmodule SpeckitOrchestrator.Store.ExportTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Export

  alias SpeckitOrchestrator.Store.Records.{
    Checkpoint,
    CostEntry,
    Escalation,
    PhaseAttempt,
    RemediationAttempt,
    SettingsAmendment,
    Transcript
  }

  @now DateTime.utc_now()
  @attempt_id {"o:repo-abc", "r000001", "003", :analyze, 1}

  defp attempt(overrides \\ %{}) do
    Map.merge(
      %PhaseAttempt{
        attempt_id: @attempt_id,
        run_key: {"o:repo-abc", "r000001"},
        feature_key: {"o:repo-abc", "r000001", "003"},
        phase: :analyze,
        ordinal: 1,
        step: 5,
        label: "analyze",
        started_at: @now,
        ended_at: @now,
        duration_ms: 91_223,
        outcome: :ok,
        model: "opus",
        cost_usd: 0.41,
        cost_kind: :actual,
        substep: nil,
        session_id: "sess-1",
        error: nil
      },
      overrides
    )
  end

  defp base_input(features) do
    %{
      exported_at: @now,
      app_version: "0.1.0",
      schema_version: 1,
      repo_id: "o:repo-abc",
      origin: "github.com/x/repo",
      run: %{
        run_id: "r000001",
        state: :completed,
        outcome: :escalated,
        started_at: @now,
        ended_at: @now,
        duration_ms: 4_821_330,
        spend_usd: 12.44,
        record_complete?: true,
        halt_reason: nil,
        scope: {:breakdown, "ledgerlite"},
        superseded_by: nil
      },
      settings: %{max_concurrency: 2},
      amendments: [],
      cost_entries: [],
      features: features
    }
  end

  defp decode(input) do
    input |> Export.encode() |> IO.iodata_to_binary() |> Jason.decode!()
  end

  describe "envelope" do
    test "format and format_version are present, no store/path/node reference" do
      doc = decode(base_input([]))

      assert doc["format"] == "speckit.run-export"
      assert doc["format_version"] == 1

      assert doc["producer"] == %{
               "app" => "speckit_orchestrator",
               "version" => "0.1.0",
               "schema_version" => 1
             }

      assert doc["repository"] == %{"repo_id" => "o:repo-abc", "origin" => "github.com/x/repo"}
      refute Map.has_key?(doc["run"], "local_path")
      refute Map.has_key?(doc["run"], "node")
      refute Map.has_key?(doc["run"], "store_dir")
    end

    test "scope encodes breakdown and ad_hoc distinctly" do
      breakdown = decode(base_input([]))
      assert breakdown["run"]["scope"] == %{"breakdown" => "ledgerlite"}

      ad_hoc_input = put_in(base_input([]).run.scope, :ad_hoc)
      assert decode(ad_hoc_input)["run"]["scope"] == "ad_hoc"
    end
  end

  describe "transcript encoding" do
    test "valid UTF-8 is inlined as utf8" do
      feature = %{
        feature_id: "003",
        slug: "ledger-entries",
        path: "specs/003",
        prereqs: [],
        status: :done,
        terminal_reason: nil,
        branch: "feature/003",
        worktree_path: nil,
        pr_description: nil,
        checkpoint: nil,
        escalations: [],
        remediation_attempts: [],
        phase_attempts: [
          %{
            attempt: attempt(),
            transcript: %Transcript{
              attempt_id: @attempt_id,
              body: "# analyze\n\n- status: ok\n",
              bytes: 25,
              written_at: @now
            }
          }
        ]
      }

      doc = decode(base_input([feature]))
      [phase_attempt] = doc["run"]["features"] |> List.first() |> Map.get("phase_attempts")
      transcript = phase_attempt["transcript"]

      assert transcript["encoding"] == "utf8"
      assert transcript["content"] == "# analyze\n\n- status: ok\n"
      assert transcript["bytes"] == 25
    end

    test "non-UTF-8 bytes round-trip byte-identically via base64" do
      raw = <<"prefix", 0xFF, 0xFE, "suffix">>

      feature = %{
        feature_id: "003",
        slug: "ledger-entries",
        path: "specs/003",
        prereqs: [],
        status: :done,
        terminal_reason: nil,
        branch: nil,
        worktree_path: nil,
        pr_description: nil,
        checkpoint: nil,
        escalations: [],
        remediation_attempts: [],
        phase_attempts: [
          %{
            attempt: attempt(),
            transcript: %Transcript{
              attempt_id: @attempt_id,
              body: raw,
              bytes: byte_size(raw),
              written_at: @now
            }
          }
        ]
      }

      doc = decode(base_input([feature]))

      transcript =
        doc["run"]["features"]
        |> List.first()
        |> Map.get("phase_attempts")
        |> List.first()
        |> Map.get("transcript")

      assert transcript["encoding"] == "base64"
      assert Base.decode64!(transcript["content"]) == raw
    end

    test "a phase attempt with no transcript encodes transcript as null" do
      feature = %{
        feature_id: "003",
        slug: "x",
        path: "specs/003",
        prereqs: [],
        status: :running,
        terminal_reason: nil,
        branch: nil,
        worktree_path: nil,
        pr_description: nil,
        checkpoint: nil,
        escalations: [],
        remediation_attempts: [],
        phase_attempts: [%{attempt: attempt(), transcript: nil}]
      }

      doc = decode(base_input([feature]))

      assert doc["run"]["features"]
             |> List.first()
             |> get_in(["phase_attempts", Access.at(0), "transcript"]) == nil
    end
  end

  describe "attempt references" do
    test "\"<feature_id>:<phase>:<ordinal>\" resolvable within the file" do
      feature = %{
        feature_id: "003",
        slug: "x",
        path: "specs/003",
        prereqs: [],
        status: :done,
        terminal_reason: nil,
        branch: nil,
        worktree_path: nil,
        pr_description: nil,
        checkpoint: %Checkpoint{
          key: {"o:repo-abc", "r000001", "003"},
          run_key: {"o:repo-abc", "r000001"},
          phase: :analyze,
          last_completed_phase: :tasks,
          status: :escalated,
          reason: "High finding",
          session_id: nil,
          implement_chunk: nil,
          analyze_remediation: %{attempts_used: 2, limit: 2},
          updated_at: @now
        },
        escalations: [
          %Escalation{
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
          }
        ],
        remediation_attempts: [
          %RemediationAttempt{
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
          }
        ],
        phase_attempts: [%{attempt: attempt(), transcript: nil}]
      }

      cost_entries = [
        %CostEntry{
          id: @attempt_id,
          run_key: {"o:repo-abc", "r000001"},
          amount_usd: 0.41,
          kind: :actual,
          recorded_at: @now
        }
      ]

      amendments = [
        %SettingsAmendment{
          id: {"o:repo-abc", "r000001", 1},
          run_key: {"o:repo-abc", "r000001"},
          ordinal: 1,
          changes: %{max_concurrency: [2, 3]},
          effective_at: @now,
          effective_after: @attempt_id
        }
      ]

      input =
        base_input([feature])
        |> Map.put(:cost_entries, cost_entries)
        |> Map.put(:amendments, amendments)

      doc = decode(input)

      assert get_in(doc, ["run", "cost_entries", Access.at(0), "attempt"]) == "003:analyze:1"

      assert get_in(doc, ["run", "settings_amendments", Access.at(0), "effective_after"]) ==
               "003:analyze:1"

      assert get_in(doc, [
               "run",
               "features",
               Access.at(0),
               "remediation_attempts",
               Access.at(0),
               "attempt"
             ]) ==
               "003:remediation:1"
    end
  end

  describe "arbitrary recorded terms" do
    test "a tuple reason is lossily-safe rather than dropped" do
      feature = %{
        feature_id: "003",
        slug: "x",
        path: "specs/003",
        prereqs: [],
        status: :halted,
        terminal_reason: {:persistence_failed, :write_timeout},
        branch: nil,
        worktree_path: nil,
        pr_description: nil,
        checkpoint: nil,
        escalations: [],
        remediation_attempts: [],
        phase_attempts: []
      }

      doc = decode(base_input([feature]))

      assert doc["run"]["features"] |> List.first() |> Map.get("terminal_reason") == [
               "persistence_failed",
               "write_timeout"
             ]
    end
  end
end
