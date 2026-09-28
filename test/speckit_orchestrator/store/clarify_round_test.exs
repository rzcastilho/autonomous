defmodule SpeckitOrchestrator.Store.ClarifyRoundTest do
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.Store.Migrations

  @repo "o:clarify-round-test"

  defp features(ids) do
    Enum.map(ids, fn id ->
      %{
        feature_id: id,
        slug: "feature-#{id}",
        path: "specs/#{id}",
        number: String.to_integer(id),
        group: :backlog,
        created_at: nil
      }
    end)
  end

  defp open(repo \\ @repo, feature_ids \\ ["001"]) do
    {:ok, run_id} =
      Writer.open_run(repo, %{
        features: features(feature_ids),
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    {repo, run_id}
  end

  defp read_feature(feature_key) do
    {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_feature_run, feature_key) end)
    {:ok, feature} = Records.decode(:speckit_feature_run, tuple)
    feature
  end

  defp read_round(round_key) do
    {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_clarify_round, round_key) end)
    {:ok, round} = Records.decode(:speckit_clarify_round, tuple)
    round
  end

  defp round_info(overrides \\ %{}) do
    Map.merge(
      %{
        round: 1,
        max_rounds: 3,
        questions_raw: "## NEEDS HUMAN\n\nwhich timezone?",
        questions: {:freeform, "which timezone?"},
        answer_timeout_s: 1_800
      },
      overrides
    )
  end

  test "migration v6 registers speckit_clarify_round and bumps current_version to 6" do
    assert Migrations.current_version() == 6
    assert :speckit_clarify_round in SpeckitOrchestrator.Store.Schema.names()
  end

  describe "record_feature_awaiting/3" do
    test "opens an :open round and sets the feature's status to :awaiting_answers" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      assert {:ok, 1} = Writer.record_feature_awaiting(run_key, "001", round_info())

      assert read_feature({repo, run_id, "001"}).status == :awaiting_answers

      round = read_round(Ids.ordinal_id(repo, run_id, "001", 1))
      assert round.outcome == :open
      assert round.round == 1
      assert round.max_rounds == 3
      assert round.seq == 1
      assert DateTime.compare(round.deadline_at, round.started_at) == :gt
    end

    test "seq is monotonic per {run_key, feature_id} across invocations, never reused" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      assert {:ok, 1} = Writer.record_feature_awaiting(run_key, "001", round_info())
      assert :ok = Writer.close_round(run_key, "001", %{seq: 1, outcome: :timed_out})
      assert {:ok, 2} = Writer.record_feature_awaiting(run_key, "001", round_info(%{round: 2}))

      assert read_round(Ids.ordinal_id(repo, run_id, "001", 1)).outcome == :timed_out
      assert read_round(Ids.ordinal_id(repo, run_id, "001", 2)).outcome == :open
    end

    test "errors on an absent feature, writing nothing" do
      {repo, run_id} = open()

      assert {:error, {:absent, _}} =
               Writer.record_feature_awaiting({repo, run_id}, "999", round_info())
    end
  end

  describe "record_feature_resumed/2" do
    test "sets the feature back to :running" do
      {repo, run_id} = open()
      run_key = {repo, run_id}

      {:ok, _seq} = Writer.record_feature_awaiting(run_key, "001", round_info())
      assert :ok = Writer.record_feature_resumed(run_key, "001")

      assert read_feature({repo, run_id, "001"}).status == :running
    end
  end

  describe "answer_round/3 — exactly one outcome wins" do
    test "commits the answer on an open, unexpired round" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())

      assert :ok =
               Writer.answer_round(run_key, "001", %{
                 seq: seq,
                 answers: %{"*" => {:typed, "UTC"}},
                 answered_via: :iex
               })

      round = read_round(Ids.ordinal_id(repo, run_id, "001", seq))
      assert round.outcome == :answered
      assert round.answers == %{"*" => {:typed, "UTC"}}
      assert round.answered_via == :iex
      refute is_nil(round.answered_at)
    end

    test "a second answer for the same seq is refused as stale, and does not overwrite the first" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())

      assert :ok =
               Writer.answer_round(run_key, "001", %{
                 seq: seq,
                 answers: %{"*" => {:typed, "first"}},
                 answered_via: :iex
               })

      assert Writer.answer_round(run_key, "001", %{
               seq: seq,
               answers: %{"*" => {:typed, "second"}},
               answered_via: :console
             }) == {:error, {:stale_round, :answered}}

      round = read_round(Ids.ordinal_id(repo, run_id, "001", seq))
      assert round.answers == %{"*" => {:typed, "first"}}
    end

    test "a close (timeout) racing an answer: whichever transaction lands first wins, the loser is refused" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())

      assert :ok = Writer.close_round(run_key, "001", %{seq: seq, outcome: :timed_out})

      assert Writer.answer_round(run_key, "001", %{
               seq: seq,
               answers: %{"*" => {:typed, "too late"}},
               answered_via: :iex
             }) == {:error, {:stale_round, :timed_out}}
    end

    test "an answer past the deadline is rejected" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info(%{answer_timeout_s: 60}))

      round_key = Ids.ordinal_id(repo, run_id, "001", seq)
      expired = read_round(round_key)

      Mnesia.transaction(fn ->
        Mnesia.write(
          Records.encode(%{expired | deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)})
        )
      end)

      assert Writer.answer_round(run_key, "001", %{
               seq: seq,
               answers: %{"*" => {:typed, "too late"}},
               answered_via: :iex
             }) == {:error, {:stale_round, :timed_out}}

      assert read_round(round_key).outcome == :open
    end

    test "answering an absent round errors" do
      {repo, run_id} = open()

      assert {:error, {:absent, _}} =
               Writer.answer_round({repo, run_id}, "001", %{
                 seq: 1,
                 answers: %{},
                 answered_via: :iex
               })
    end
  end

  describe "close_round/3" do
    test "flips an open round to the given outcome and stamps closed_at" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())

      assert :ok = Writer.close_round(run_key, "001", %{seq: seq, outcome: :breaker})

      round = read_round(Ids.ordinal_id(repo, run_id, "001", seq))
      assert round.outcome == :breaker
      refute is_nil(round.closed_at)
    end

    test "fails, and writes nothing, when the round is already answered" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())

      :ok =
        Writer.answer_round(run_key, "001", %{
          seq: seq,
          answers: %{"*" => {:typed, "UTC"}},
          answered_via: :iex
        })

      assert Writer.close_round(run_key, "001", %{seq: seq, outcome: :drained}) ==
               {:error, {:stale_round, :answered}}

      round = read_round(Ids.ordinal_id(repo, run_id, "001", seq))
      assert round.outcome == :answered
    end
  end

  describe "mark_round_applied/2" do
    test "sets applied_at once and is idempotent on a second call" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())
      round_key = Ids.ordinal_id(repo, run_id, "001", seq)

      assert :ok = Writer.mark_round_applied(round_key)
      first = read_round(round_key).applied_at
      refute is_nil(first)

      assert :ok = Writer.mark_round_applied(round_key, DateTime.add(DateTime.utc_now(), 60))
      assert read_round(round_key).applied_at == first
    end

    test "errors on an absent round" do
      {repo, run_id} = open()
      assert {:error, {:absent, _}} = Writer.mark_round_applied(Ids.ordinal_id(repo, run_id, "001", 99))
    end
  end

  # ---- 029, research.md R12 (T047/T054) --------------------------------------

  describe "reconcile_awaiting_answers/2" do
    test "closes the open round :interrupted, escalates the feature, and keeps the questions" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, seq} = Writer.record_feature_awaiting(run_key, "001", round_info())

      assert :ok = Writer.reconcile_awaiting_answers(run_key, "001")

      feature = read_feature({repo, run_id, "001"})
      assert feature.status == :escalated
      assert feature.terminal_reason == {:needs_human, :restart}
      refute is_nil(feature.ended_at)

      round = read_round(Ids.ordinal_id(repo, run_id, "001", seq))
      assert round.outcome == :interrupted
      refute is_nil(round.closed_at)
      assert round.questions_raw == round_info().questions_raw

      {:ok, [tuple]} =
        Mnesia.transaction(fn -> Mnesia.index_read(:speckit_escalation, run_key, :run_key) end)

      {:ok, escalation} = Records.decode(:speckit_escalation, tuple)
      assert escalation.reason == {:needs_human, :restart}
      assert escalation.evidence == %{questions: round_info().questions_raw}
    end

    test "works even with no open round (already answered/closed) — feature still escalates" do
      {repo, run_id} = open()
      run_key = {repo, run_id}
      {:ok, _seq} = Writer.record_feature_awaiting(run_key, "001", round_info())
      :ok = Writer.record_feature_resumed(run_key, "001")

      assert :ok = Writer.reconcile_awaiting_answers(run_key, "001")
      assert read_feature({repo, run_id, "001"}).status == :escalated
    end

    test "errors on an absent feature" do
      {repo, run_id} = open()
      assert {:error, {:absent, _}} = Writer.reconcile_awaiting_answers({repo, run_id}, "nope")
    end
  end
end
