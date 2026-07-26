defmodule SpeckitOrchestrator.ResumeBacklogE2ETest do
  # async: false — swaps global SDK + app env; runs the real stack end-to-end
  # (mirrors facade_e2e_test.exs's conventions).
  #
  # 016 T037 / quickstart.md S6: reproduces the exact `../quickpoll` failure
  # from the spec's "Context" section — resuming a diverted first feature in a
  # three-feature chained backlog used to erase the record of the other two
  # (`Done: 1` instead of `Done: 3`). Proves it fixed end-to-end, not just at
  # the seam level (resume_scope_test.exs covers the seam level with a fake
  # runner; this drives a real Coordinator/FeatureRunner/Worktree stack against
  # an offline fake SDK).
  use ExUnit.Case, async: false

  @moduletag :integration

  # Offline end-to-end fake: writes the real artifacts a phase would produce
  # (mirrors facade_e2e_test.exs's FakeSDK/FakeArtifacts pairing) and gates
  # `:analyze` on a toggle the test flips between the initial run (which must
  # halt) and the resume (which must succeed) — set once, globally, exactly
  # like resume_test.exs's ChunkFakeSDK toggles `:chunk_fake_illegal_phases`.
  # A single boolean suffices: only the first feature's first analyze attempt
  # happens before the toggle flips; every later analyze call (that feature's
  # retry, and every dependent's own first attempt) happens after.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, opts) do
      SpeckitOrchestrator.FakeArtifacts.write(prompt, opts)

      text =
        cond do
          String.contains?(prompt, "clarify reviewer") -> "Clarified."
          String.contains?(prompt, "/speckit.analyze") -> analyze_result()
          true -> "done"
        end

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
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end

    defp analyze_result do
      if Application.get_env(:speckit_orchestrator, :e2e_gate_cleared, false) do
        ~s({"summary":"ok","findings":[]})
      else
        ~s({"summary":"blocked","findings":[{"severity":"critical","title":"bad"}]})
      end
    end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp add_origin!(repo),
    do: git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])

  defp breakdown_file(repo, id, prereq_line) do
    File.write!(
      Path.join(repo, "specs/autonomous/breakdown/core/#{id}-core.md"),
      "# #{id}\n\n## Prerequisites\n\n#{prereq_line}\n"
    )
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    prev_gate = Application.get_env(:speckit_orchestrator, :e2e_gate_cleared)

    prev =
      for k <- [:repo, :breakdown_dir, :worktree_root, :autonomous_root],
          do: {k, Application.get_env(:speckit_orchestrator, k)}

    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.delete_env(:speckit_orchestrator, :e2e_gate_cleared)

    repo = Path.join(System.tmp_dir!(), "e2e_backlog_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "e2e_backlog_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, "specs/autonomous/breakdown/core"))

    breakdown_file(repo, "001", "None")
    breakdown_file(repo, "002", "- 001 Core")
    breakdown_file(repo, "003", "- 002 Core")

    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    add_origin!(repo)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])

    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "docs/breakdown")
    Application.put_env(:speckit_orchestrator, :worktree_root, root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      if prev_gate,
        do: Application.put_env(:speckit_orchestrator, :e2e_gate_cleared, prev_gate),
        else: Application.delete_env(:speckit_orchestrator, :e2e_gate_cleared)

      for {k, v} <- prev do
        if v,
          do: Application.put_env(:speckit_orchestrator, k, v),
          else: Application.delete_env(:speckit_orchestrator, k)
      end

      File.rm_rf(repo)
      File.rm_rf(root)
    end)

    %{repo: repo, root: root}
  end

  test "a resume after a gate divert continues the whole three-feature backlog to :done, not just the resumed feature" do
    {:ok, pid} = SpeckitOrchestrator.run(owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # First run: 001 diverts at analyze (critical finding); 002/003 never
    # start (blocked on 001, per Release's dependency gate). Pre-016 this
    # already matched — the divert itself isn't the defect, resuming past it
    # while keeping 002/003 in the record is.
    assert_receive {:run_complete, first_report}, 30_000
    assert first_report.halted == ["001"]
    assert first_report.done == []

    # Manifest still names all three going into the resume — this is the
    # exact defect surface: a pre-016 resume/2 would collapse this to one.
    {:ok, record} = SpeckitOrchestrator.RunManifest.read()
    assert Enum.sort(Enum.map(record["features"], & &1["id"])) == ["001", "002", "003"]
    assert Enum.sort(Map.keys(record["statuses"])) == ["001", "002", "003"]

    # Operator fix: the condition that produced the critical finding is
    # resolved before the resume — mirrors a real remediation.
    Application.put_env(:speckit_orchestrator, :e2e_gate_cleared, true)

    me = self()
    assert {:ok, resumed_pid} = SpeckitOrchestrator.resume("001", owner: me)
    on_exit(fn -> if Process.alive?(resumed_pid), do: GenServer.stop(resumed_pid) end)

    assert_receive {:run_complete, final_report}, 30_000
    assert Enum.sort(final_report.done) == ["001", "002", "003"]
    assert final_report.halted == []
  end
end
