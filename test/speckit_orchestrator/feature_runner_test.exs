defmodule SpeckitOrchestrator.FeatureRunnerTest do
  # async: false — swaps the global :jido_claude sdk_module + a scenario flag.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, FeatureRunner, Ledger, Worktree}

  # Fake SDK that branches on the prompt so a single fake drives every phase.
  # The scenario is read from app env so each test picks happy/escalate/halt.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _options) do
      text = response_text(prompt)

      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{type: :assistant, data: %{session_id: "s", message: %{"content" => text}}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.10},
          raw: %{}
        }
      ]
    end

    defp response_text(prompt) do
      scenario = Application.get_env(:speckit_orchestrator, :test_fake_scenario, :happy)

      cond do
        String.contains?(prompt, "clarify reviewer") ->
          if scenario == :escalate,
            do: "Reviewed the spec.\n\n## NEEDS HUMAN\nProration semantics unspecified.",
            else: "Clarified: all ambiguities resolved from the constitution."

        String.contains?(prompt, "/speckit.analyze") ->
          case scenario do
            :halt -> ~s({"summary":"violation","findings":[{"severity":"critical","title":"float money"}]})
            :bad_analyze -> "No JSON here, just prose — malformed analyze output."
            _ -> ~s({"summary":"clean","findings":[]})
          end

        true ->
          "Phase completed."
      end
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :happy)

    on_exit(fn ->
      if prev_sdk, do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :test_fake_scenario)
    end)

    :ok
  end

  defp feature, do: %Feature{id: "001", slug: "core-ledger", path: "docs/breakdown/001-core-ledger.md"}

  # --- real base repo + worktree for the containment assertions ---
  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_worktree do
    repo = Path.join(System.tmp_dir!(), "fr_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "fr_root_#{System.unique_integer([:positive])}")
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

  test "happy path: runs the full pipeline to :done and removes the worktree" do
    wt = scaffolded_worktree()
    {:ok, ledger} = Ledger.start_link(budget: 100, name: nil)

    result = FeatureRunner.run(feature(), worktree: wt, ledger: ledger, notify: self())

    assert result.status == :done
    assert result.cost_total > 0
    assert_received {:feature_finished, "001", :done, _}
    refute File.dir?(wt.path)
    assert Ledger.spent(ledger) == result.cost_total
  end

  test "clarify escalation: stops at :escalated and keeps the worktree" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :escalated
    assert_received {:feature_finished, "001", :escalated, :needs_human}
    assert File.dir?(wt.path)
  end

  test "analyze critical: stops at :halted and keeps the worktree" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :halted
    assert_received {:feature_finished, "001", :halted, :critical_finding}
    assert File.dir?(wt.path)
  end

  test "runs without a worktree (dry run in base repo), notify as a function" do
    me = self()
    notify = fn id, status, reason -> send(me, {:notified, id, status, reason}) end
    result = FeatureRunner.run(feature(), notify: notify)
    assert result.status == :done
    assert_received {:notified, "001", :done, _}
  end

  test "malformed analyze JSON fails the feature at analyze (never a silent pass)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :bad_analyze)
    result = FeatureRunner.run(feature(), notify: self())
    assert result.status == :failed
    assert result.reason == {:analyze, :error}
  end

  test "a phase call timeout marks the feature :failed" do
    # 1ms timeout forces the call to die; the runner catches and fails the feature.
    result = FeatureRunner.run(feature(), phase_timeout: 1, notify: self())
    assert result.status == :failed
    assert_received {:feature_finished, "001", :failed, _}
  end
end
