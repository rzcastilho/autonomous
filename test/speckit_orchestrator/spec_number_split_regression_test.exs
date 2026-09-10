defmodule SpeckitOrchestrator.SpecNumberSplitRegressionTest do
  @moduledoc """
  FR-017: the observed production failure, reproduced end to end, with all
  three feature-022 pieces wired together exactly as they run in production —
  no injected `:runner`/`:executor` seam, a real git repo and worktree, and a
  fake `claude` CLI that writes real files rather than returning cheerful text.

  The scenario: a wave restarts numbering at `001` against a target repository
  that already carries a finished `specs/001-existing/` from an earlier wave
  (User Story 1's defect), and this feature's `tasks` phase — the
  artifact-producing phase FR-017 names — reports success while writing
  nothing (User Story 2's defect). Both defects are live in the same run, so
  this is also the only test that proves resolving *this* feature's `tasks.md`
  never quietly settles for the collision target's already-complete one
  (User Story 3) — the exact mechanism that turned a stalled `tasks` phase
  into a misleading failure three phases downstream (spec.md "Why this
  priority").
  """

  # async: false — StoreCase clears the node-global Mnesia store, and this
  # test swaps the global :jido_claude sdk_module.
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Feature, RepoIdentity}

  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    # Writes real artifacts for `specify`/`plan`, exactly like a working
    # session would, but reports success for `tasks` having written nothing —
    # the observed false-green this whole feature exists to catch.
    def query(prompt, options) do
      cwd = cwd_of(options)

      cond do
        String.contains?(prompt, "/speckit.specify") -> write_specify(prompt, cwd)
        String.contains?(prompt, "/speckit.plan") -> write_plan(cwd)
        true -> :ok
      end

      success_messages()
    end

    defp cwd_of(%{cwd: cwd}), do: cwd
    defp cwd_of(options) when is_list(options), do: Keyword.get(options, :cwd)
    defp cwd_of(_), do: nil

    # `PhaseRequest` pins `SPECIFY_FEATURE_DIRECTORY=specs/<spec_id>-<slug>`
    # verbatim into the specify prompt — the real CLI's own source of truth
    # for where to write, so the fake reads the same text instead of guessing
    # a directory name.
    defp write_specify(prompt, cwd) do
      [_, dir] = Regex.run(~r{SPECIFY_FEATURE_DIRECTORY=(specs/[\w-]+)\.}, prompt)
      path = Path.join(cwd, dir)
      File.mkdir_p!(path)
      File.write!(Path.join(path, "spec.md"), "# Spec\n\nReal feature spec, nothing ambiguous.\n")
      Application.put_env(:speckit_orchestrator, :regression_spec_dir, dir)
    end

    # `plan`'s prompt carries no directory of its own — the CLI (and this
    # fake) locates its own feature by the directory `specify` already wrote.
    defp write_plan(cwd) do
      dir = Application.fetch_env!(:speckit_orchestrator, :regression_spec_dir)
      path = Path.join(cwd, dir)
      File.write!(Path.join(path, "plan.md"), "# Plan\n\nReal implementation plan, not a template.\n")
    end

    defp success_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: "done", is_error: false, total_cost_usd: 0.1},
          raw: %{}
        }
      ]
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :regression_spec_dir)
    end)

    :ok
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_repo do
    repo =
      Path.join(System.tmp_dir!(), "speckit_regression_repo_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Constitution\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    File.mkdir_p!(Path.join(repo, ".claude/hooks"))
    File.write!(Path.join(repo, ".claude/hooks/scope_guard.py"), "")

    # The earlier wave's finished feature this wave's "001" collides with —
    # complete, with every task checked off, so a resolution leak would make
    # `tasks` look done rather than empty.
    File.mkdir_p!(Path.join(repo, "specs/001-existing"))
    File.write!(Path.join(repo, "specs/001-existing/spec.md"), "# 001 existing\n")
    File.write!(Path.join(repo, "specs/001-existing/plan.md"), "# 001 existing plan\n")
    File.write!(Path.join(repo, "specs/001-existing/tasks.md"), "- [X] T001 already done\n")

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "earlier wave"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp point_config_at(repo, root) do
    prev = for k <- [:repo, :worktree_root], do: {k, Application.get_env(:speckit_orchestrator, k)}
    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :worktree_root, root)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:speckit_orchestrator, k, v),
          else: Application.delete_env(:speckit_orchestrator, k)
      end
    end)
  end

  defp branch_exists?(repo, branch),
    do:
      match?(
        {_, 0},
        System.cmd("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"])
      )

  test "a colliding, empty-tasks feature fails at tasks, alone, without ever resolving the collision's files" do
    repo = scaffolded_repo()
    root = Path.join(System.tmp_dir!(), "speckit_regression_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    point_config_at(repo, root)

    # Same wave-local number "001" as the earlier wave's finished feature —
    # the collision User Story 1 exists to resolve.
    feature = %Feature{id: "001", number: 1, slug: "newthing", path: "001-newthing.md"}

    {:ok, pid} = SpeckitOrchestrator.run(features: [feature], owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 15_000

    # Fails, at exactly this feature, never silently "done".
    assert report.failed == ["001"]

    # Net one prerequisite (US1): the collision was resolved to a fresh spec
    # number and a differently-named branch/directory, not the colliding "001".
    refute branch_exists?(repo, "feature/001-newthing")
    assert branch_exists?(repo, "feature/002-newthing")

    repo_id = RepoIdentity.partition(repo)
    {:ok, [%{run_id: run_id} | _]} = SpeckitOrchestrator.Store.runs(repo_id)
    run_key = {repo_id, run_id}
    assert SpeckitOrchestrator.Store.spec_number(run_key, "001") == 2

    {:ok, detail} = SpeckitOrchestrator.Store.Query.run(run_key)
    [feature_detail] = detail.features

    # Fails at the artifact-producing phase that wrote nothing (FR-017), not
    # some unrelated-sounding phase downstream — analyze/implement never ran.
    # Whichever of the two independent nets fires first — the pre-existing
    # artifact gate (`{:missing_artifact, :tasks, _}`) or feature 022's new
    # empty-checkpoint net (`{:empty_checkpoint, :tasks}`) — FR-017 only
    # requires the failure to land at `:tasks`, named, with no cascade.
    assert match?({:missing_artifact, :tasks, _}, feature_detail.terminal_reason) or
             match?({:empty_checkpoint, :tasks}, feature_detail.terminal_reason)

    refute Enum.any?(feature_detail.phase_attempts, &(&1.phase in [:analyze, :implement]))

    # A failed feature keeps its worktree for post-mortem (architecture note).
    # Real runs resolve the worktree root through `Layout` (machine-global,
    # keyed by repository identity — `Config.worktree_root/0` is legacy and
    # unused by the executor), so locate the worktree it actually created by
    # its unambiguous leaf name rather than re-deriving that path here.
    autonomous_root = Application.get_env(:speckit_orchestrator, :autonomous_root) |> Path.expand()
    {:ok, segment} = SpeckitOrchestrator.RepoIdentity.resolve(repo)
    worktree_path = Path.join([autonomous_root, "worktrees", segment, "002-newthing"])
    on_exit(fn -> File.rm_rf(Path.join([autonomous_root, "worktrees", segment])) end)

    # US3/net one: this feature's own directory carries its own real content —
    # never the collision target's.
    own_dir = Path.join(worktree_path, "specs/002-newthing")
    assert File.read!(Path.join(own_dir, "spec.md")) =~ "nothing ambiguous"
    assert File.read!(Path.join(own_dir, "plan.md")) =~ "not a template"
    refute File.exists?(Path.join(own_dir, "tasks.md"))

    # The collision target itself is untouched — its complete task list was
    # never adopted, edited, or otherwise treated as this feature's own.
    assert File.read!(Path.join(repo, "specs/001-existing/tasks.md")) == "- [X] T001 already done\n"
  end
end
