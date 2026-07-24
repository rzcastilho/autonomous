defmodule SpeckitOrchestrator.RecoveryTest do
  # async: false — real worktree/git fixtures + global :transcript_root/
  # :autonomous_root/:repo/:jido_claude sdk_module app env (mirrors
  # resume_test.exs / recovery_quickpoll_test.exs conventions).
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{
    Checkpoint,
    Feature,
    Layout,
    Recovery,
    Recovery.Evidence,
    RepoIdentity,
    RunContext,
    RunManifest
  }

  @coordinator SpeckitOrchestrator.Coordinator

  # Generic FakeSDK — every phase "completes" with plain text and writes no
  # real output file, so an artifact-gated phase (:plan/:tasks/:implement)
  # always trips the missing-artifact gate. That is exploited here as an
  # independent, side-channel proof of which phase a resumed run actually
  # started at (quickstart.md Scenario 2): if reconciliation resumes at
  # `:tasks`, the run fails at `:tasks` with a missing-artifact reason and
  # `.speckit_logs/04-tasks.md` exists while `01-specify.md`/`02-clarify.md`/
  # `03-plan.md` do not — proving `specify`/`clarify`/`plan` were never
  # regenerated.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, _options) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{session_id: "s", message: %{"content" => "Phase completed."}},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "Phase completed.",
            is_error: false,
            total_cost_usd: 0.01
          },
          raw: %{}
        }
      ]
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "rt_#{System.unique_integer([:positive])}")
    prev_transcript = Application.get_env(:speckit_orchestrator, :transcript_root)
    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
    prev_repo = Application.get_env(:speckit_orchestrator, :repo)
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)

    Application.put_env(:speckit_orchestrator, :transcript_root, root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    stop_coordinator()

    on_exit(fn ->
      stop_coordinator()
      File.rm_rf(root)

      if prev_transcript,
        do: Application.put_env(:speckit_orchestrator, :transcript_root, prev_transcript),
        else: Application.delete_env(:speckit_orchestrator, :transcript_root)

      if prev_autonomous,
        do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev_autonomous),
        else: Application.delete_env(:speckit_orchestrator, :autonomous_root)

      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)

      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)
    end)

    :ok
  end

  defp stop_coordinator do
    case Process.whereis(@coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # Carries the committed `.specify`/`.claude` scaffold `Worktree.create/2`
  # asserts on (mirrors resume_test.exs's base_repo/0), plus an `origin`
  # remote so `RepoIdentity.resolve/1` succeeds.
  defp base_repo do
    repo = Path.join(System.tmp_dir!(), "rt_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "Tester"])
    git!(repo, ["remote", "add", "origin", "https://example.com/recovery.git"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp commit(repo, message) do
    File.write!(Path.join(repo, "f_#{System.unique_integer([:positive])}.txt"), message)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "core-ledger", path: "#{id}.md", prereqs: prereqs}

  defp write_manifest(overrides) do
    :ok =
      RunManifest.write(
        Map.merge(
          %{
            features: [],
            statuses: %{},
            context: %RunContext{pr_workflow: false, max_concurrency: 1, budget_usd: 100.0},
            spend: 5.0,
            updated_at: 1
          },
          overrides
        )
      )
  end

  # quickstart.md Scenario 2: a feature reached an intermediate phase —
  # boundary commits through `plan` only, no `pr.json`, checkpoint
  # `last_phase: plan / in_progress`.
  defp seed_mid_run_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after specify")
    commit(repo, "speckit: 001 checkpoint after clarify")
    commit(repo, "speckit: 001 checkpoint after plan")
    git!(repo, ["checkout", "-q", "main"])

    :ok =
      Checkpoint.write(%{
        feature_id: "001",
        last_phase: :plan,
        status: :in_progress,
        reason: "test fixture",
        session_id: "s1",
        slug: "core-ledger",
        path: "001.md",
        layout: layout
      })

    write_manifest(%{
      features: [feat("001")],
      statuses: %{"001" => :running},
      layout: layout
    })

    layout
  end

  test "reconcile_run/2 resumes a mid-run feature at the phase after its latest boundary" do
    layout = seed_mid_run_state()

    {:ok, record} = RunManifest.read()

    assert {:ok, %{statuses: statuses, resume_phases: resume_phases}} =
             Recovery.reconcile_run(record)

    assert statuses["001"] == :running
    assert resume_phases["001"] == :tasks

    {:ok, reread} = RunManifest.read()
    assert reread["statuses"]["001"] == "running"

    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
  end

  # ---- US3 (T018): whole-run status coverage ---------------------------------
  #
  # One manifest exercising every status class (running/pending/escalated/
  # halted/failed/done) against matching or conflicting evidence, plus a
  # feature dependent on the conflict feature (must stay blocked) and a
  # feature dependent on the reconciled `:done` feature (must release,
  # proving one conflict never freezes the rest of the DAG — FR-014).
  defp write_pr(layout, id) do
    dir = Path.join(layout.transcript_root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "pr.json"), Jason.encode!(%{pr_title: "t", pr_body: "b"}))
  end

  defp seed_whole_run_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core-ledger"})

    # 001: running, PR-workflow done-signal (branch + pr.json) -> reconciles :done
    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])
    write_pr(layout, "001")

    # 006: recorded done, but NO branch / NO pr.json -> {:conflict, :done_without_artifacts}

    write_manifest(%{
      features: [
        feat("001"),
        feat("002", ["001"]),
        feat("003"),
        feat("004"),
        feat("005"),
        feat("006"),
        feat("007", ["006"])
      ],
      statuses: %{
        "001" => :running,
        "002" => :pending,
        "003" => :escalated,
        "004" => :halted,
        "005" => :failed,
        "006" => :done,
        "007" => :pending
      },
      layout: layout
    })

    layout
  end

  test "reconcile_run/2 reconciles every status class in one whole-run pass" do
    layout = seed_whole_run_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, record} = RunManifest.read()

    assert {:ok, %{statuses: statuses, report: report}} = Recovery.reconcile_run(record)

    assert statuses["001"] == :done
    assert statuses["002"] == :pending
    assert statuses["003"] == :escalated
    assert statuses["004"] == :halted
    assert statuses["005"] == :failed
    assert statuses["006"] == :blocked
    assert statuses["007"] == :pending

    assert %{id: "006", reason: :done_without_artifacts} in report.conflicts

    # Independent, non-dependent-on-the-conflict feature releases normally.
    assert "002" in report.next_runnable
    # The conflict feature itself never releases (not :pending).
    refute "006" in report.next_runnable
    # A dependent of the conflict feature stays blocked — one conflict never
    # freezes the rest of the run.
    refute "007" in report.next_runnable

    {:ok, reread} = RunManifest.read()
    assert reread["statuses"]["001"] == "done"
    assert reread["statuses"]["002"] == "pending"
    assert reread["statuses"]["003"] == "escalated"
    assert reread["statuses"]["004"] == "halted"
    assert reread["statuses"]["005"] == "failed"
    assert reread["statuses"]["006"] == "blocked"
    assert reread["statuses"]["007"] == "pending"
  end

  test "resume_run/1 dispatches continuation at :tasks — specify/clarify/plan never regenerate" do
    layout = seed_mid_run_state()
    me = self()

    assert {:ok, pid} = SpeckitOrchestrator.resume_run(owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 10_000
    assert report.failed == ["001"]

    log_dir = Path.join(layout.worktree_root, "001-core-ledger/.speckit_logs")
    refute File.exists?(Path.join(log_dir, "01-specify.md"))
    refute File.exists?(Path.join(log_dir, "02-clarify.md"))
    refute File.exists?(Path.join(log_dir, "03-plan.md"))
    assert File.exists?(Path.join(log_dir, "04-tasks.md"))

    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
  end

  # ---- US4 (T022/T023): both run shapes reconcile correctly -----------------

  defp converge_ready, do: "Tests green, committed.\n\n## CONVERGE: READY\n"

  defp write_final_marker(layout, id) do
    dir = Path.join(layout.transcript_root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "07-converge.md"), converge_ready())
  end

  # T022: ad-hoc run whose single feature finished before a crash — non-PR
  # done-signal (converge marker + committed branch, no pr.json).
  defp seed_ad_hoc_done_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    write_final_marker(layout, "001")

    write_manifest(%{
      features: [feat("001")],
      statuses: %{"001" => :running},
      layout: layout
    })

    layout
  end

  test "reconcile_run/2 (T022): ad-hoc run derives :ad_hoc shape and reconciles the finished feature to :done" do
    layout = seed_ad_hoc_done_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, record} = RunManifest.read()

    assert {:ok, %{statuses: statuses, report: report, resume_phases: resume_phases}} =
             Recovery.reconcile_run(record)

    assert report.run_shape == :ad_hoc
    assert statuses["001"] == :done
    refute Map.has_key?(resume_phases, "001")
    assert report.next_runnable == []
    assert Enum.find(report.features, &(&1.id == "001")).reconciled == :done
  end

  # T023: breakdown-wave run — a finished upstream feature releases its
  # pending dependent on continuation.
  defp seed_breakdown_wave_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core-ledger"})

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    write_pr(layout, "001")

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"])],
      statuses: %{"001" => :running, "002" => :pending},
      layout: layout
    })

    layout
  end

  test "reconcile_run/2 (T023): breakdown-wave run derives {:breakdown, slug} shape and releases the dependent" do
    layout = seed_breakdown_wave_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, record} = RunManifest.read()

    assert {:ok, %{statuses: statuses, report: report}} = Recovery.reconcile_run(record)

    assert report.run_shape == {:breakdown, "core-ledger"}
    assert statuses["001"] == :done
    assert statuses["002"] == :pending
    assert "002" in report.next_runnable
  end

  # ---- Phase 7 (T026): offline resilience — SC-009 -----------------------
  #
  # Reconciliation must never fail, and every feature must still reach its
  # correct status from local durable state alone, when the remote-PR probe
  # is unreachable — the default `:remote` seam is already local-only
  # (`Evidence.default_remote/1` -> :unknown, no network touched); this test
  # goes further and proves the same holds even when a real remote probe is
  # *injected* and errors (simulating an unreachable `gh`/network call),
  # exercising `Evidence.safe_remote/2`'s rescue path end-to-end through
  # `Recovery.reconcile_run/2` rather than unit-testing `Evidence.collect/3`
  # in isolation (already covered by evidence_test.exs).
  test "reconcile_run/2 (T026): an unreachable remote seam never blocks reconciliation — every feature resolves from local evidence alone" do
    layout = seed_breakdown_wave_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, record} = RunManifest.read()

    unreachable_remote = fn _feature_id -> raise "simulated network timeout" end

    assert {:ok, %{statuses: statuses, report: report}} =
             Recovery.reconcile_run(record, remote: unreachable_remote)

    # Same reconciled outcome as the reachable-network case (T023) — the
    # remote probe is never authoritative, only opportunistic.
    assert report.run_shape == {:breakdown, "core-ledger"}
    assert statuses["001"] == :done
    assert statuses["002"] == :pending
    assert "002" in report.next_runnable

    # "002" has no local pr.json, so the collector attempts the remote probe
    # for it and must degrade the raise to :unknown rather than propagating.
    evidence_002 =
      Evidence.collect(feat("002"), layout, remote: unreachable_remote)

    assert evidence_002.pr_record? == false
    assert evidence_002.pr_remote? == :unknown

    # "001" has a local pr.json, so the remote seam is never consulted for it.
    evidence_001 = Evidence.collect(feat("001"), layout, remote: unreachable_remote)
    assert evidence_001.pr_record? == true
    assert evidence_001.pr_remote? == :unknown
  end

  # ---- Phase 7 (T027): manifest missing/corrupt fail-loud -----------------
  #
  # Per contracts/recovery-report.md "Errors": a missing/corrupt manifest
  # propagates as `{:error, :no_manifest | :corrupt}` — recovery never
  # fabricates a run (Principle II). `reconcile_run/2` itself only ever sees
  # an already-read record, so its own contract surface is the "corrupt"
  # half (a record missing `"features"`/`"statuses"`); "no_manifest" is
  # `RunManifest.read/0`'s concern, upstream of any `reconcile_run/2` call —
  # asserted here directly so the boundary is explicit rather than assumed.
  test "reconcile_run/2 (T027): a malformed record (missing features/statuses) returns {:error, :corrupt}, never fabricates a run" do
    assert {:error, :corrupt} = Recovery.reconcile_run(%{"not" => "a manifest"})
    assert {:error, :corrupt} = Recovery.reconcile_run(%{})
  end

  test "reconcile_run/2 (T027): an absent manifest is caught by RunManifest.read/0 before reconcile_run/2 is ever called" do
    assert {:error, :no_manifest} = RunManifest.read()
  end
end
