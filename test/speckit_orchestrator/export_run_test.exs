defmodule SpeckitOrchestrator.ExportRunTest do
  use SpeckitOrchestrator.StoreCase, async: false

  @moduledoc """
  `SpeckitOrchestrator.export_run/3` (018, T019, contracts/export-format.md)
  — writes exactly one self-describing JSON file, read-only, available
  mid-run.
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "speckit_export_run_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])

    {_, 0} =
      System.cmd("git", [
        "-C",
        dir,
        "remote",
        "add",
        "origin",
        "https://github.com/x/export-fixture.git"
      ])

    prev = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, dir)

    on_exit(fn ->
      File.rm_rf(dir)

      if prev,
        do: Application.put_env(:speckit_orchestrator, :repo, prev),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    {:ok, repo: dir}
  end

  test "writes exactly one self-describing JSON file with the run's own repo_id", %{repo: repo} do
    repo_id = SpeckitOrchestrator.RepoIdentity.partition(repo)

    {:ok, run_id} =
      Store.open_run(repo_id, %{
        features: [
          %{feature_id: "001", slug: "f", path: "specs/001", number: 1, group: :backlog, created_at: nil}
        ],
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    Store.record_phase_attempt({repo_id, run_id}, %{
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
      transcript: "specify output"
    })

    out =
      Path.join(System.tmp_dir!(), "export_run_test_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(out) end)

    assert {:ok, ^out} = SpeckitOrchestrator.export_run(run_id, out)
    assert File.exists?(out)

    {:ok, doc} = out |> File.read!() |> Jason.decode()
    assert doc["format"] == "speckit.run-export"
    assert doc["run"]["run_id"] == run_id
    assert doc["repository"]["repo_id"] == repo_id
    assert doc["repository"]["origin"] == "github.com/x/export-fixture"

    [feature] = doc["run"]["features"]
    [phase_attempt] = feature["phase_attempts"]
    assert phase_attempt["transcript"]["content"] == "specify output"
  end

  test "an unknown run_id returns {:error, :absent}", %{repo: repo} do
    out =
      Path.join(
        System.tmp_dir!(),
        "export_run_test_absent_#{System.unique_integer([:positive])}.json"
      )

    assert {:error, :absent} = SpeckitOrchestrator.export_run("r999999", out, repo: repo)
  end
end
