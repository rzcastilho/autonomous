defmodule Autonomous.FeatureRunnerEngineTest do
  # Feature 046: the end-of-phase container-engine sweep seam in FeatureRunner.
  # async: false — swaps the global :jido_claude sdk_module and a scenario flag.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Autonomous.{Feature, FeatureRunner, RunContext, StubEngineCli, Worktree}

  # Minimal fake SDK: every phase succeeds, with a few scenario switches.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      Autonomous.FakeArtifacts.write(prompt, options)
      text = response_text(prompt, Application.get_env(:autonomous, :test_fake_scenario, :happy))

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
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.10},
          raw: %{}
        }
      ]
    end

    defp response_text(prompt, scenario) do
      cond do
        String.contains?(prompt, "clarify reviewer") and scenario == :escalate ->
          "Reviewed.\n\n## NEEDS HUMAN\nProration semantics unspecified."

        String.contains?(prompt, "clarify reviewer") ->
          "Clarified: all ambiguities resolved."

        String.contains?(prompt, "pull-request description") ->
          ~s|{"commit_message":"feat(001): built","pr_title":"Add","pr_body":"## Summary\\n- built"}|

        String.contains?(prompt, "/speckit-analyze") ->
          ~s({"summary":"clean","findings":[]})

        String.contains?(prompt, "ready for human PR review") ->
          "Tests green, committed.\n\n## CONVERGE: READY"

        true ->
          "Phase completed."
      end
    end
  end

  setup do
    prev = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:autonomous, :test_fake_scenario, :happy)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:jido_claude, :sdk_module, prev),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:autonomous, :test_fake_scenario)
    end)

    id = "fr-engine-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      id,
      [:speckit, :engine, :cleanup],
      fn _e, _m, meta, _ -> send(test, {:cleanup, meta.phase, meta.result}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  defp feature,
    do: %Feature{
      id: "001",
      number: 1,
      slug: "core-ledger",
      path: "docs/breakdown/001-core-ledger.md"
    }

  defp loop_off, do: %RunContext{auto_remediation: false}

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_worktree do
    repo = Path.join(System.tmp_dir!(), "fre_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "fre_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 6}))
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(root)
    end)

    {:ok, wt} = Worktree.create(feature(), repo: repo, worktree_root: root, base: "HEAD")
    wt
  end

  defp empty(["ps", "-aq"]), do: {:ok, ""}
  defp empty(["rm" | _]), do: {:ok, ""}
  defp empty(["network", "prune" | _]), do: {:ok, ""}
  defp empty(["volume", "prune" | _]), do: {:ok, ""}
  defp empty(["network", "ls" | _]), do: {:ok, ""}
  defp empty(["volume", "ls" | _]), do: {:ok, ""}

  defp engine(cli), do: [advertised?: true, cli: cli]

  defp drain_cleanups(acc \\ []) do
    receive do
      {:cleanup, phase, result} -> drain_cleanups([{phase, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @phases [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]

  test "one cleanup per phase boundary, :implement once, plus remediation and describe" do
    cli = StubEngineCli.new(&empty/1)
    wt = scaffolded_worktree()

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        run_context: loop_off(),
        remediation_prompt: "Fix the thing.",
        engine: engine(cli)
      )

    assert result.status == :done

    assert drain_cleanups() ==
             Enum.map([:remediation | @phases] ++ [:describe], &{&1, :clean})
  end

  test "a gate divert still sweeps the phase that diverted" do
    Application.put_env(:autonomous, :test_fake_scenario, :escalate)
    cli = StubEngineCli.new(&empty/1)

    result =
      FeatureRunner.run(feature(),
        worktree: scaffolded_worktree(),
        notify: self(),
        engine: engine(cli)
      )

    assert result.status == :escalated
    assert drain_cleanups() == [specify: :clean, clarify: :clean]
  end

  test "a failed phase (session death) still sweeps and the run still terminates" do
    cli = StubEngineCli.new(&empty/1)
    # no worktree artifacts: a dry run against a bare repo fails an artifact gate
    result =
      FeatureRunner.run(feature(), phase_timeout: 200, notify: self(), engine: engine(cli))

    assert result.status in [:failed, :done]
    assert [{:specify, _} | _] = drain_cleanups()
  end

  @tag capture_log: true
  test "the phase outcome is identical with clean, residue and crashed cleanup" do
    clean = StubEngineCli.new(&empty/1)

    residue =
      StubEngineCli.new(fn
        ["volume", "ls" | _] -> {:ok, "v1\n"}
        args -> empty(args)
      end)

    crashed = StubEngineCli.new(fn _ -> raise "boom" end)

    outcomes =
      for cli <- [clean, residue, crashed] do
        result =
          FeatureRunner.run(feature(),
            worktree: scaffolded_worktree(),
            notify: self(),
            run_context: loop_off(),
            engine: engine(cli)
          )

        {result.status, result.reason, result.cost_total}
      end

    assert [same, same, same] = outcomes
    assert {:done, _, _} = same
  end

  test "residue is logged at error level with the phase and never changes the result" do
    residue =
      StubEngineCli.new(fn
        ["volume", "ls" | _] -> {:ok, "v1\n"}
        a -> empty(a)
      end)

    log =
      capture_log(fn ->
        result =
          FeatureRunner.run(feature(),
            worktree: scaffolded_worktree(),
            notify: self(),
            run_context: loop_off(),
            engine: engine(residue)
          )

        assert result.status == :done
      end)

    assert log =~ "cleanup after feature 001 (specify) left 0 containers, 0 networks, 1 volumes"
    assert log =~ "(describe)"
  end

  test "advertised?: false and the default suite make zero cleanup calls" do
    cli = StubEngineCli.new(&empty/1)

    FeatureRunner.run(feature(),
      worktree: scaffolded_worktree(),
      notify: self(),
      run_context: loop_off(),
      engine: [advertised?: false, cli: cli]
    )

    assert [] = StubEngineCli.calls(cli)
    assert [] = drain_cleanups()

    # no :engine option at all, no AUTONOMOUS_CONTAINER_ENGINE in the test env
    FeatureRunner.run(feature(),
      worktree: scaffolded_worktree(),
      notify: self(),
      run_context: loop_off()
    )

    assert [] = drain_cleanups()
  end
end
