defmodule Autonomous.ConsoleHistoryTest do
  use ExUnit.Case, async: true

  alias Autonomous.{ConsoleHistory, ConsoleReadModel}

  @t ~U[2026-10-09 10:00:00Z]

  defp attempt(phase, from, to, outcome),
    do: %{
      phase: phase,
      attempt_id: "a-#{phase}-#{from}",
      started_at: from && DateTime.add(@t, from),
      ended_at: to && DateTime.add(@t, to),
      outcome: outcome,
      cost_usd: 0.5
    }

  defp feature(id, extra \\ %{}) do
    Map.merge(
      %{
        feature_id: id,
        status: :done,
        terminal_reason: nil,
        pr_url: nil,
        ended_at: DateTime.add(@t, 100),
        phase_attempts: [attempt(:specify, 1, 10, :ok), attempt(:plan, 11, 20, :error)]
      },
      extra
    )
  end

  defp detail(features),
    do: %{run: %{key: {"r", "1"}, started_at: @t}, cost_entries: [], features: features}

  test "entries, texts and severities" do
    model = ConsoleHistory.rebuild(detail([feature("001", %{pr_url: "http://pr"})]), @t)
    feed = Enum.reverse(model.feed)

    assert Enum.map(feed, & &1.text) == [
             "run started",
             "phase specify started",
             "phase specify -> :ok",
             "phase plan started",
             "phase plan -> :error",
             "feature terminal done (nil)",
             "PR opened: http://pr"
           ]

    assert Enum.find(feed, &(&1.text == "phase plan -> :error")).severity == :error
    assert model.run_key == {"r", "1"}
    assert MapSet.size(model.rebuilt_keys) == 7
    assert %{spend: _, phases: %{specify: _}} = model.features["001"]
    assert model.features["001"].chunk_cost_seen == 0.0
  end

  test "interleaves features chronologically, ties broken by rank then id" do
    f2 = feature("002", %{phase_attempts: [attempt(:specify, 5, 6, :ok)]})
    model = ConsoleHistory.rebuild(detail([feature("001"), f2]), @t)
    ats = model.feed |> Enum.reverse() |> Enum.map(& &1.at)
    assert ats == Enum.sort(ats, DateTime)
  end

  test ":implement_chunk attempts excluded and missing timestamps skipped" do
    f =
      feature("001", %{
        ended_at: nil,
        status: :running,
        phase_attempts: [attempt(:implement_chunk, 1, 2, :ok), attempt(:specify, nil, nil, :ok)]
      })

    model = ConsoleHistory.rebuild(detail([f]), @t)
    assert Enum.map(model.feed, & &1.text) == ["run started"]
  end

  test "keeps only the newest 200" do
    attempts = for i <- 1..150, do: attempt(:specify, i * 2, i * 2 + 1, :ok)

    f = feature("001", %{phase_attempts: attempts, ended_at: DateTime.add(@t, 1_000)})
    model = ConsoleHistory.rebuild(detail([f]), @t)
    assert length(model.feed) == 200
    assert hd(model.feed).text =~ "feature terminal"
  end

  test "nil and empty details give an empty model" do
    assert ConsoleHistory.rebuild(nil) == ConsoleReadModel.new()
    assert ConsoleHistory.rebuild(detail([])) == ConsoleReadModel.new()
  end
end
