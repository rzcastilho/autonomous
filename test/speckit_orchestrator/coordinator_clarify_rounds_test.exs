defmodule SpeckitOrchestrator.CoordinatorClarifyRoundsTest do
  # A store-backed Coordinator run (needs a real `run_key`, unlike
  # coordinator_test.exs's plain unit tests) — StoreCase clears every table
  # first so an earlier test's rounds never leak in.
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, Layout, RepoIdentity}

  @repo "o:coordinator-clarify-rounds-test"

  defp feat(id, number), do: %Feature{id: id, number: number, slug: "f#{id}", path: "#{id}.md"}

  defp open_run(feature_ids) do
    repo_id = RepoIdentity.partition(@repo)
    {:ok, layout} = Layout.build(@repo, repo_id, :ad_hoc)

    features =
      Enum.with_index(feature_ids, 1)
      |> Enum.map(fn {id, n} ->
        %{feature_id: id, slug: "f#{id}", path: "#{id}.md", number: n, group: :backlog, created_at: nil}
      end)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings: %{},
        scope: :ad_hoc,
        layout: layout
      })

    {repo_id, run_id}
  end

  test "clarify_rounds is populated per feature that opened a round, and absent for one that didn't" do
    {repo_id, run_id} = open_run(["001", "002"])
    run_key = {repo_id, run_id}

    {:ok, seq} =
      Writer.record_feature_awaiting(run_key, "001", %{
        round: 1,
        max_rounds: 3,
        questions_raw: "## NEEDS HUMAN\n\nwhich timezone?",
        questions: {:freeform, "which timezone?"},
        answer_timeout_s: 1_800
      })

    :ok =
      Writer.answer_round(run_key, "001", %{
        seq: seq,
        answers: %{"*" => {:typed, "UTC"}},
        answered_via: :iex
      })

    {:ok, pid} =
      Coordinator.start_link(
        features: [feat("001", 1), feat("002", 2)],
        runner: fn feature, notify -> notify.(feature.id, :done, nil) end,
        owner: self(),
        run_key: run_key
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 1_000

    assert %{"001" => [%{round: 1, seq: ^seq, outcome: :answered}]} = report.clarify_rounds
    refute Map.has_key?(report.clarify_rounds, "002")
  end

  test "clarify_rounds is %{} when no feature ever opened a round (mode off)" do
    {repo_id, run_id} = open_run(["003"])
    run_key = {repo_id, run_id}

    {:ok, pid} =
      Coordinator.start_link(
        features: [feat("003", 1)],
        runner: fn feature, notify -> notify.(feature.id, :done, nil) end,
        owner: self(),
        run_key: run_key
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 1_000
    assert report.clarify_rounds == %{}
  end
end
