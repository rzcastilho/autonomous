defmodule SpeckitOrchestrator.ExportTest do
  use SpeckitOrchestrator.StoreCase, async: false

  @moduledoc """
  Facade-level `export_run/3` (018 Phase 6, T071, contracts/export-format.md).
  Exactly one self-describing file; the store can be torn down entirely and
  everything is still recoverable from the file alone (SC-016); a non-UTF-8
  transcript round-trips byte-identically via `"encoding": "base64"`; export
  works mid-run and under a capacity refusal, and changes nothing either way.
  """

  alias SpeckitOrchestrator.{RepoIdentity, RunContext, Store}

  @non_utf8 <<0xC3, 0x28>>

  setup do
    dir =
      Path.join(System.tmp_dir!(), "speckit_export_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", "https://x/export.git"])

    prev = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:speckit_orchestrator, :repo, prev),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    {:ok, repo: dir, repo_id: RepoIdentity.partition(dir)}
  end

  defp out_path do
    Path.join(System.tmp_dir!(), "export_test_#{System.unique_integer([:positive])}.json")
  end

  defp phase_attempt(feature_id, phase, ordinal, transcript) do
    now = DateTime.utc_now()

    %{
      attempt: %{
        feature_id: feature_id,
        phase: phase,
        ordinal: ordinal,
        step: ordinal,
        label: Atom.to_string(phase),
        started_at: now,
        ended_at: now,
        duration_ms: 5,
        outcome: :ok,
        model: "sonnet",
        cost_usd: 0.05,
        cost_kind: :actual
      },
      cost: %{amount_usd: 0.05, kind: :actual},
      transcript: transcript
    }
  end

  defp seed_full_run(repo_id) do
    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [%{feature_id: "001", slug: "f", path: "specs/001", prereqs: []}],
        settings: RunContext.to_map(%RunContext{max_concurrency: 2}),
        scope: :ad_hoc,
        layout: %{}
      })

    run_key = {repo_id, run_id}

    :ok = Writer.record_settings_amendment(run_key, %{max_concurrency: [2, 3]}, nil)
    :ok = Writer.record_phase_attempt(run_key, phase_attempt("001", :specify, 1, "utf8 output"))
    :ok = Writer.record_phase_attempt(run_key, phase_attempt("001", :plan, 2, @non_utf8))

    :ok =
      Writer.record_remediation_attempt(run_key, %{
        remediation: %{
          feature_id: "001",
          ordinal: 1,
          findings: [],
          max_severity: :high,
          outcome: :ok,
          cost_usd: 0.1,
          attempt_limit: 2,
          threshold: :high,
          model: "opus"
        },
        phase_attempt: %{
          step: 3,
          label: "analyze",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 5,
          outcome: :ok,
          model: "opus",
          cost_usd: 0.1,
          cost_kind: :actual
        },
        transcript: "remediation output"
      })

    :ok =
      Writer.record_escalation(run_key, %{
        feature_id: "001",
        kind: :escalated,
        phase: :analyze,
        reason: "High finding",
        evidence: %{}
      })

    :ok = Writer.record_feature_terminal(run_key, "001", :escalated, "High finding")
    :ok = Writer.close_run(run_key, :escalated)

    {run_key, run_id}
  end

  test "writes exactly one file, self-contained after the store is torn down entirely (SC-016)",
       %{repo: repo, repo_id: repo_id} do
    {_run_key, run_id} = seed_full_run(repo_id)

    out = out_path()
    on_exit(fn -> File.rm(out) end)

    assert {:ok, ^out} = SpeckitOrchestrator.export_run(run_id, out, repo: repo)
    assert File.exists?(out)
    assert [_] = Path.wildcard(Path.join(Path.dirname(out), Path.basename(out) <> "*"))

    # Tear the store down entirely — the export must stand on its own, with
    # zero further store reads required to reconstruct it.
    Enum.each(Schema.names(), &Mnesia.clear_table/1)

    {:ok, doc} = out |> File.read!() |> Jason.decode()

    assert doc["format"] == "speckit.run-export"
    assert doc["format_version"] == 1
    assert doc["repository"]["repo_id"] == repo_id
    assert doc["repository"]["origin"] == "x/export"
    assert doc["run"]["run_id"] == run_id
    assert doc["run"]["outcome"] == "escalated"
    assert doc["run"]["settings"]["max_concurrency"] == 2
    assert [%{"ordinal" => 1}] = doc["run"]["settings_amendments"]
    assert [_, _] = doc["run"]["cost_entries"]

    [feature] = doc["run"]["features"]
    assert feature["feature_id"] == "001"
    assert feature["status"] == "escalated"
    assert [%{"ordinal" => 1, "reason" => "High finding"}] = feature["escalations"]
    assert [%{"ordinal" => 1}] = feature["remediation_attempts"]
    assert length(feature["phase_attempts"]) == 3

    utf8 = Enum.find(feature["phase_attempts"], &(&1["phase"] == "specify"))
    assert utf8["transcript"]["encoding"] == "utf8"
    assert utf8["transcript"]["content"] == "utf8 output"

    non_utf8 = Enum.find(feature["phase_attempts"], &(&1["phase"] == "plan"))
    assert non_utf8["transcript"]["encoding"] == "base64"
    assert Base.decode64!(non_utf8["transcript"]["content"]) == @non_utf8
  end

  test "an unknown run_id returns {:error, :absent} without writing a file", %{repo: repo} do
    out = out_path()
    refute {:ok, out} == File.read(out)
    assert {:error, :absent} = SpeckitOrchestrator.export_run("r999999", out, repo: repo)
    refute File.exists?(out)
  end

  test "export mid-run (before close) works and changes nothing", %{
    repo: repo,
    repo_id: repo_id
  } do
    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [%{feature_id: "001", slug: "f", path: "specs/001", prereqs: []}],
        settings: RunContext.to_map(%RunContext{}),
        scope: :ad_hoc,
        layout: %{}
      })

    before_size = Mnesia.table_info(:speckit_run, :size)

    out = out_path()
    on_exit(fn -> File.rm(out) end)
    assert {:ok, ^out} = SpeckitOrchestrator.export_run(run_id, out, repo: repo)

    {:ok, doc} = out |> File.read!() |> Jason.decode()
    assert doc["run"]["state"] == "in_flight"

    assert Mnesia.table_info(:speckit_run, :size) == before_size
    assert {:ok, %{run: %{run_id: ^run_id, state: :in_flight}}} = Store.run({repo_id, run_id})
  end

  test "export under a capacity refusal works and changes nothing", %{
    repo: repo,
    repo_id: repo_id
  } do
    {_run_key, run_id} = seed_full_run(repo_id)

    prev_capacity = Application.get_env(:speckit_orchestrator, :store_capacity_bytes)
    prev_headroom = Application.get_env(:speckit_orchestrator, :store_headroom_bytes)
    Application.put_env(:speckit_orchestrator, :store_capacity_bytes, 1)
    Application.put_env(:speckit_orchestrator, :store_headroom_bytes, 1)

    on_exit(fn ->
      if prev_capacity,
        do: Application.put_env(:speckit_orchestrator, :store_capacity_bytes, prev_capacity),
        else: Application.delete_env(:speckit_orchestrator, :store_capacity_bytes)

      if prev_headroom,
        do: Application.put_env(:speckit_orchestrator, :store_headroom_bytes, prev_headroom),
        else: Application.delete_env(:speckit_orchestrator, :store_headroom_bytes)
    end)

    assert {:ok, %{status: :refusing}} = SpeckitOrchestrator.store_capacity()

    before_size = Mnesia.table_info(:speckit_run, :size)

    out = out_path()
    on_exit(fn -> File.rm(out) end)
    assert {:ok, ^out} = SpeckitOrchestrator.export_run(run_id, out, repo: repo)
    assert File.exists?(out)

    assert Mnesia.table_info(:speckit_run, :size) == before_size
  end
end
