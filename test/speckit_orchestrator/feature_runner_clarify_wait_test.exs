defmodule SpeckitOrchestrator.FeatureRunnerClarifyWaitTest do
  # async: false — swaps the global :jido_claude sdk_module + test app env,
  # same discipline as feature_runner_test.exs. Every test opens its own
  # store-backed run under a unique repo id so runs never collide.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, FeatureRunner, Ledger, RunContext, Worktree, Workers}
  alias SpeckitOrchestrator.Store.{Mnesia, Query, Records, Writer}

  # A FakeSDK whose clarify response is round-aware: it keeps escalating
  # `## NEEDS HUMAN` until a test-controlled call count is reached (or never,
  # for the rounds-exhausted scenario), then clears. Every other phase
  # completes plainly, writing the artifacts the plan/tasks/implement gates
  # require via the shared `FakeArtifacts` helper.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      SpeckitOrchestrator.FakeArtifacts.write(prompt, options)
      text = response_text(prompt)

      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{session_id: "s", message: %{"content" => text}},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.01},
          raw: %{}
        }
      ]
    end

    defp response_text(prompt) do
      cond do
        String.contains?(prompt, "clarify reviewer") -> clarify_text()
        String.contains?(prompt, "pull-request description") -> pr_json()
        String.contains?(prompt, "/speckit.analyze") -> ~s({"summary":"clean","findings":[]})
        String.contains?(prompt, "ready for human PR review") -> "Tests green.\n\n## CONVERGE: READY"
        true -> "Phase completed."
      end
    end

    defp pr_json,
      do: ~s|{"commit_message":"feat: built","pr_title":"t","pr_body":"b"}|

    defp clarify_text do
      n = next_clarify_call()
      clears_at = Application.get_env(:speckit_orchestrator, :test_clarify_clears_at, 1)

      if clears_at != :never and n >= clears_at do
        "Clarified: all ambiguities resolved from the constitution."
      else
        "Reviewed the spec.\n\n## NEEDS HUMAN\nWhich timezone does billing use?"
      end
    end

    defp next_clarify_call do
      case Application.get_env(:speckit_orchestrator, :test_clarify_counter) do
        nil -> 1
        agent -> Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      end
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    prev_poll = Application.get_env(:speckit_orchestrator, :clarify_poll_ms)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    # Fast polling so a real timeout/rounds-exhausted scenario resolves in
    # milliseconds rather than the production default (1s).
    Application.put_env(:speckit_orchestrator, :clarify_poll_ms, 20)
    Application.put_env(:speckit_orchestrator, :test_clarify_counter, counter)
    Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, 1)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      if prev_poll,
        do: Application.put_env(:speckit_orchestrator, :clarify_poll_ms, prev_poll),
        else: Application.delete_env(:speckit_orchestrator, :clarify_poll_ms)

      Application.delete_env(:speckit_orchestrator, :test_clarify_counter)
      Application.delete_env(:speckit_orchestrator, :test_clarify_clears_at)
      if Process.alive?(counter), do: Agent.stop(counter)
    end)

    :ok
  end

  defp feature,
    do: %Feature{
      id: "001",
      number: 1,
      slug: "core-ledger",
      path: "docs/breakdown/001-core-ledger.md"
    }

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_worktree do
    repo = Path.join(System.tmp_dir!(), "fcw_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "fcw_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(root)
    end)

    {:ok, wt} = Worktree.create(feature(), repo: repo, worktree_root: root)
    wt
  end

  defp open_store_run do
    repo_id = "o:clarify-wait-test-#{System.unique_integer([:positive])}"

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: "001",
            slug: "core-ledger",
            path: "specs/001",
            number: 1,
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    {repo_id, run_id}
  end

  defp interactive_context(overrides \\ []) do
    struct(
      %RunContext{interactive_clarify: true, clarify_answer_timeout_s: 60, clarify_max_rounds: 3},
      overrides
    )
  end

  defp store_status(run_key, feature_id) do
    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)

    case Enum.find(detail.features, &(&1.feature_id == feature_id)) do
      nil -> nil
      f -> f.status
    end
  end

  defp wait_until(fun, tries \\ 300) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(10)
        wait_until(fun, tries - 1)

      false when tries > 0 ->
        Process.sleep(10)
        wait_until(fun, tries - 1)

      result ->
        result
    end
  end

  defp wait_until_awaiting(run_key, feature_id) do
    wait_until(fn ->
      case store_status(run_key, feature_id) do
        :awaiting_answers -> true
        _ -> false
      end
    end) || flunk("feature never reached :awaiting_answers")
  end

  defp open_round(run_key, feature_id) do
    wait_until(fn ->
      run_key |> Query.open_clarify_rounds() |> Enum.find(&(&1.feature_id == feature_id))
    end) || flunk("round never opened")
  end

  defp expire_round(round) do
    Mnesia.transaction(fn ->
      Mnesia.write(
        Records.encode(%{round | deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)})
      )
    end)
  end

  # ---- US1 (T037-T039) -------------------------------------------------------

  describe "mode on — US1" do
    test "clarify NEEDS HUMAN enters :awaiting_answers, worktree retained, no spend while waiting" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      {:ok, ledger} = Ledger.start_link(budget: 100, name: nil)
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, :never)

      task =
        Task.async(fn ->
          FeatureRunner.run(feature(),
            worktree: wt,
            ledger: ledger,
            run_context: interactive_context(),
            run_key: run_key
          )
        end)

      wait_until_awaiting(run_key, "001")
      round = open_round(run_key, "001")
      assert round.round == 1
      assert round.max_rounds == 3
      assert File.dir?(wt.path)

      spent_while_waiting = Ledger.spent(ledger)
      Process.sleep(120)
      assert Ledger.spent(ledger) == spent_while_waiting

      Task.shutdown(task, :brutal_kill)
    end

    test "answer_round/3 triggers the clarify re-run and the feature proceeds past clarify" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, 2)

      task =
        Task.async(fn ->
          FeatureRunner.run(feature(),
            worktree: wt,
            run_context: interactive_context(),
            run_key: run_key
          )
        end)

      round = open_round(run_key, "001")
      assert round.questions_raw =~ "Which timezone does billing use?"

      :ok =
        Writer.answer_round(run_key, "001", %{
          seq: round.seq,
          answers: %{"*" => {:typed, "UTC"}},
          answered_via: :iex
        })

      result = Task.await(task, 5_000)

      assert result.status == :done
      refute File.dir?(wt.path)

      # The round the operator answered is recorded, and its answer applied.
      answered_round = run_key |> ordinal_id("001", round.seq) |> read_round()
      assert answered_round.outcome == :answered
      refute is_nil(answered_round.applied_at)
    end

    test "mode off: NEEDS HUMAN escalates exactly as before, byte-identical" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, :never)

      result =
        FeatureRunner.run(feature(),
          worktree: wt,
          run_context: %RunContext{interactive_clarify: false},
          run_key: run_key
        )

      assert result.status == :escalated
      assert result.reason == :needs_human
      assert File.dir?(wt.path)
      assert store_status(run_key, "001") == :escalated
    end
  end

  # ---- US2 (T050-T053) -------------------------------------------------------

  describe "mode on — US2 fallbacks" do
    test "an expired deadline escalates {:needs_human, :answer_timeout}" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, :never)

      task =
        Task.async(fn ->
          FeatureRunner.run(feature(),
            worktree: wt,
            run_context: interactive_context(),
            run_key: run_key
          )
        end)

      round = open_round(run_key, "001")
      expire_round(round)

      result = Task.await(task, 5_000)
      assert result.status == :escalated
      assert result.reason == {:needs_human, :answer_timeout}
      assert store_status(run_key, "001") == :escalated
    end

    test "a tripped breaker while waiting escalates with no further spend" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      {:ok, ledger} = Ledger.start_link(budget: 100, name: nil)
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, :never)

      task =
        Task.async(fn ->
          FeatureRunner.run(feature(),
            worktree: wt,
            ledger: ledger,
            run_context: interactive_context(),
            run_key: run_key
          )
        end)

      open_round(run_key, "001")
      spend_before = Ledger.spent(ledger)
      Ledger.record(ledger, nil, 1_000)

      result = Task.await(task, 5_000)
      assert result.status == :escalated
      assert result.reason == {:needs_human, :breaker}
      # The only additional "spend" is the breaker trip itself, not a session.
      assert Ledger.spent(ledger) == spend_before + 1_000
    end

    test "Workers.drain/1 returns quickly regardless of the (long) answer timeout" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      {repo_id, _run_id} = run_key
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, :never)

      {:ok, _pid} =
        Workers.spawn(run_key, "001", fn ->
          FeatureRunner.run(feature(),
            worktree: wt,
            run_context: interactive_context(clarify_answer_timeout_s: 86_400),
            run_key: run_key
          )
        end)

      open_round(run_key, "001")
      # Let the tick loop's own `Workers.waiting/1` overwrite the long
      # clarify-session deadline the phase call just before the wait
      # published, so the drain bound below reflects the *wait's* short
      # deadline, not the just-finished session's.
      Process.sleep(100)

      # Default bound/margins (not zeroed, unlike workers_test.exs's stubs —
      # this worker does real finalize work: a worktree commit + store
      # writes). `await_all_down/2` returns as soon as the worker actually
      # exits, so this proves the point without needing to wait out the full
      # bound: nowhere near the 86_400s answer timeout (SC-005).
      {elapsed_us, result} = :timer.tc(fn -> Workers.drain(repo_id) end)

      assert result == :ok
      assert elapsed_us < 10_000_000

      wait_until(fn ->
        case store_status(run_key, "001") do
          :escalated -> true
          _ -> false
        end
      end)

      assert store_status(run_key, "001") == :escalated
    end

    test "rounds exhausted: opens rounds 1..max, then escalates {:needs_human, :rounds_exhausted}" do
      wt = scaffolded_worktree()
      run_key = open_store_run()
      Application.put_env(:speckit_orchestrator, :test_clarify_clears_at, :never)

      task =
        Task.async(fn ->
          FeatureRunner.run(feature(),
            worktree: wt,
            run_context: interactive_context(clarify_max_rounds: 2),
            run_key: run_key
          )
        end)

      round1 = open_round(run_key, "001")
      assert round1.round == 1

      :ok =
        Writer.answer_round(run_key, "001", %{
          seq: round1.seq,
          answers: %{"*" => {:typed, "still doesn't resolve it"}},
          answered_via: :iex
        })

      round2 = open_round(run_key, "001")
      assert round2.round == 2
      assert round2.seq == round1.seq + 1

      :ok =
        Writer.answer_round(run_key, "001", %{
          seq: round2.seq,
          answers: %{"*" => {:typed, "still doesn't resolve it"}},
          answered_via: :iex
        })

      result = Task.await(task, 5_000)
      assert result.status == :escalated
      assert result.reason == {:needs_human, :rounds_exhausted}

      # T042, data-model.md Escalation.evidence: the final unanswered
      # question block and how many rounds were spent on it.
      escalation = read_escalation(run_key, "001")
      assert escalation.reason == {:needs_human, :rounds_exhausted}
      assert %{questions: raw, rounds_used: 2} = escalation.evidence
      assert raw =~ "Which timezone does billing use?"
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp read_escalation(run_key, feature_id) do
    {:ok, tuples} =
      Mnesia.transaction(fn -> Mnesia.index_read(:speckit_escalation, run_key, :run_key) end)

    tuples
    |> Enum.map(fn tuple ->
      {:ok, escalation} = Records.decode(:speckit_escalation, tuple)
      escalation
    end)
    |> Enum.find(&(&1.feature_id == feature_id))
  end

  defp read_round(round_key) do
    {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_clarify_round, round_key) end)
    {:ok, round} = Records.decode(:speckit_clarify_round, tuple)
    round
  end

  defp ordinal_id({repo_id, run_id}, feature_id, seq),
    do: SpeckitOrchestrator.Store.Ids.ordinal_id(repo_id, run_id, feature_id, seq)
end
