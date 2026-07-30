defmodule SpeckitOrchestrator.RecoveryTest do
  # async: false — real worktree/git fixtures + global :transcript_root/
  # :autonomous_root/:repo/:jido_claude sdk_module app env, plus the shared
  # store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{
    Feature,
    Layout,
    Recovery,
    Recovery.Evidence,
    RepoIdentity,
    RunContext
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

  defp feat(id, number \\ nil),
    do: %Feature{
      id: id,
      number: number || String.to_integer(id),
      slug: "core-ledger",
      path: "#{id}.md"
    }

  # ---- store seeding (018) ---------------------------------------------------

  defp scope_of(%Layout{breakdown_root: nil}), do: :ad_hoc
  defp scope_of(%Layout{in_repo_rel: rel}), do: {:breakdown, Path.basename(rel)}

  defp open_run(repo, layout, features) do
    repo_id = RepoIdentity.partition(repo)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features:
          Enum.map(
            features,
            &%{
              feature_id: &1.id,
              slug: &1.slug,
              path: &1.path,
              number: &1.number,
              group: &1.group,
              created_at: &1.created_at
            }
          ),
        settings:
          RunContext.to_map(%RunContext{
            budget_usd: 100.0
          }),
        scope: scope_of(layout),
        layout: layout
      })

    {repo_id, run_id}
  end

  defp minimal_attempt(feature_id, phase, ordinal) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: ordinal,
      step: 1,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :ok,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # Interrupted mid-run: a checkpoint (+ the phase attempt that produced it)
  # recording "next phase after plan is tasks" — `store_recorded_status/1`
  # derives `:running` from the checkpoint's presence alone.
  defp seed_running(run_key, feature_id, resume_phase, last_completed) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, last_completed, 1),
        checkpoint: %{
          phase: resume_phase,
          last_completed_phase: last_completed,
          status: :in_progress,
          reason: nil,
          session_id: "s1"
        }
      })
  end

  # A non-PR done-signal: a `:converge` phase attempt whose transcript
  # carries the ready marker — no checkpoint, so `store_recorded_status/1`
  # still derives `:running` from the phase attempt alone.
  defp seed_converge_marker(run_key, feature_id) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, :converge, 1),
        transcript: "Tests green, committed.\n\n## CONVERGE: READY\n"
      })
  end

  defp seed_terminal(run_key, feature_id, status, opts \\ []) do
    :ok = Writer.record_feature_terminal(run_key, feature_id, status, :test_fixture, opts)
  end

  # quickstart.md Scenario 2: a feature reached an intermediate phase —
  # boundary commits through `plan` only, no PR record, checkpoint recording
  # "resume at tasks".
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

    run_key = open_run(repo, layout, [feat("001")])
    seed_running(run_key, "001", :tasks, :plan)

    {layout, run_key}
  end

  test "reconcile_run/2 resumes a mid-run feature at the phase after its latest boundary" do
    {layout, run_key} = seed_mid_run_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)

    assert {:ok, %{statuses: statuses, resume_phases: resume_phases}} =
             Recovery.reconcile_run(detail)

    assert statuses["001"] == :running
    assert resume_phases["001"] == :tasks
  end

  # ---- US3 (T018): whole-run status coverage ---------------------------------
  #
  # One run exercising every status class (running/pending/escalated/
  # halted/failed/done) against matching or conflicting evidence. 019: there
  # are no prerequisites/dependents anymore — `next_runnable` is
  # `Release.next/3`'s own single-feature-at-a-time preview, and its rule 2
  # (find the lowest-ordered escalated/halted/failed feature, anywhere in the
  # ordered set) means **any** broken feature stops the whole numeric chain,
  # not just its old dependents — the opposite of the pre-019 DAG's
  # per-branch isolation.
  defp seed_whole_run_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core-ledger"})

    # 001: real evidence (branch + PR record) but recorded terminal already
    # — the store commits pr_description in the same transaction as :done
    # (unlike the pre-018 file model, this cannot legitimately disagree), so
    # this exercises Reconcile clause 3 (done requires corroboration) rather
    # than clause 4's upgrade — same evidence, same reconciled outcome.
    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    features = [
      feat("001"),
      feat("002"),
      feat("003"),
      feat("004"),
      feat("005"),
      feat("006"),
      feat("007")
    ]

    run_key = open_run(repo, layout, features)

    seed_terminal(run_key, "001", :done, pr_description: %{pr_title: "t", pr_body: "b"})
    # 002: pending, never released.
    seed_terminal(run_key, "003", :escalated)
    seed_terminal(run_key, "004", :halted)
    seed_terminal(run_key, "005", :failed)
    # 006: recorded done, but NO branch / NO PR record -> {:conflict, :done_without_artifacts}
    seed_terminal(run_key, "006", :done)
    # 007: pending.

    {layout, run_key}
  end

  test "reconcile_run/2 reconciles every status class in one whole-run pass" do
    {layout, run_key} = seed_whole_run_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)

    assert {:ok, %{statuses: statuses, report: report}} = Recovery.reconcile_run(detail)

    assert statuses["001"] == :done
    assert statuses["002"] == :pending
    assert statuses["003"] == :escalated
    assert statuses["004"] == :halted
    assert statuses["005"] == :failed
    assert statuses["006"] == :blocked
    assert statuses["007"] == :pending

    assert %{id: "006", reason: :done_without_artifacts} in report.conflicts

    # 019: "003" (escalated) is the lowest-ordered non-done-terminal feature
    # in the whole set — `Release.next/3` rule 2 stops the entire numeric
    # chain there, so nothing is next-runnable at all, even though "002" is
    # itself merely :pending and precedes "003".
    assert report.next_runnable == []
  end

  test "resume_run/1 dispatches continuation at :tasks — specify/clarify/plan never regenerate" do
    {layout, run_key} = seed_mid_run_state()
    me = self()

    # `seed_mid_run_state/0` itself plants a :plan phase attempt (the
    # fixture's own "plan just finished" checkpoint marker) — captured here so
    # the post-run assertion can prove that row was never touched, rather than
    # merely asserting :plan is present (which the seed guarantees regardless).
    seeded_plan_attempt =
      Store.run(run_key)
      |> elem(1)
      |> Map.fetch!(:features)
      |> hd()
      |> Map.fetch!(:phase_attempts)
      |> Enum.find(&(&1.phase == :plan))

    assert {:ok, pid} = SpeckitOrchestrator.resume_run(owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 10_000
    assert report.failed == ["001"]

    {:ok, detail} = Store.run(run_key)
    phases = detail.features |> hd() |> Map.fetch!(:phase_attempts)
    refute Enum.any?(phases, &(&1.phase == :specify))
    refute Enum.any?(phases, &(&1.phase == :clarify))
    assert Enum.any?(phases, &(&1.phase == :tasks))
    assert Enum.find(phases, &(&1.phase == :plan)) == seeded_plan_attempt

    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
  end

  # ---- US4 (T022/T023): both run shapes reconcile correctly -----------------

  # T022: ad-hoc run whose single feature finished before a crash — non-PR
  # done-signal (converge marker + committed branch, no PR record).
  defp seed_ad_hoc_done_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    run_key = open_run(repo, layout, [feat("001")])
    seed_converge_marker(run_key, "001")

    {layout, run_key}
  end

  test "reconcile_run/2 (T022): ad-hoc run derives :ad_hoc shape and reconciles the finished feature to :done" do
    {layout, run_key} = seed_ad_hoc_done_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)

    assert {:ok, %{statuses: statuses, report: report, resume_phases: resume_phases}} =
             Recovery.reconcile_run(detail)

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

    run_key = open_run(repo, layout, [feat("001"), feat("002")])
    seed_terminal(run_key, "001", :done, pr_description: %{pr_title: "t", pr_body: "b"})

    {layout, run_key}
  end

  test "reconcile_run/2 (T023): breakdown-wave run derives {:breakdown, slug} shape and releases the dependent" do
    {layout, run_key} = seed_breakdown_wave_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)

    assert {:ok, %{statuses: statuses, report: report}} = Recovery.reconcile_run(detail)

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
    {layout, run_key} = seed_breakdown_wave_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)
    unreachable_remote = fn _feature_id -> raise "simulated network timeout" end

    assert {:ok, %{statuses: statuses, report: report}} =
             Recovery.reconcile_run(detail, remote: unreachable_remote)

    # Same reconciled outcome as the reachable-network case (T023) — the
    # remote probe is never authoritative, only opportunistic.
    assert report.run_shape == {:breakdown, "core-ledger"}
    assert statuses["001"] == :done
    assert statuses["002"] == :pending
    assert "002" in report.next_runnable

    feature_records = Map.new(detail.features, &{&1.feature_id, &1})

    # "002" has no local PR record, so the collector attempts the remote
    # probe for it and must degrade the raise to :unknown rather than
    # propagating.
    evidence_002 =
      Evidence.collect(feat("002"), feature_records["002"], remote: unreachable_remote)

    assert evidence_002.pr_record? == false
    assert evidence_002.pr_remote? == :unknown

    # "001" has a recorded PR description, so the remote seam is never
    # consulted for it.
    evidence_001 =
      Evidence.collect(feat("001"), feature_records["001"], remote: unreachable_remote)

    assert evidence_001.pr_record? == true
    assert evidence_001.pr_remote? == :unknown
  end

  # ---- Phase 7 (T027): record missing/corrupt fail-loud -----------------
  #
  # Per contracts/recovery-report.md "Errors": a missing/damaged run record
  # propagates rather than fabricating a run (Principle II). `reconcile_run/2`
  # itself only ever sees an already-read record, so its own contract surface
  # is the "corrupt" half (a record not shaped like a store run detail);
  # "no run" is `Store.current_run_key/1`'s concern, upstream of any
  # `reconcile_run/2` call — asserted here directly so the boundary is
  # explicit rather than assumed (018).
  test "reconcile_run/2 (T027): a malformed record (not shaped like a store run detail) returns {:error, :corrupt}, never fabricates a run" do
    assert {:error, :corrupt} = Recovery.reconcile_run(%{"not" => "a manifest"})
    assert {:error, :corrupt} = Recovery.reconcile_run(%{})
  end

  test "reconcile_run/2 (T027): an absent run is caught before reconcile_run/2 is ever called" do
    assert {:error, :no_manifest} = SpeckitOrchestrator.resumable("o:no-such-repo-recovery-test")
  end

  # ---- T032 (016 US3, research.md D4): plan_run/2 vs reconcile_run/2 split --

  defmodule CountingWriter do
    def record_feature_terminal(_run_key, _feature_id, _status, _reason, _opts) do
      Process.put(:t032_writes, Process.get(:t032_writes, 0) + 1)
      :ok
    end
  end

  test "plan_run/2 returns the same {:ok, %{statuses, resume_phases, report}} shape but performs no write" do
    {layout, run_key} = seed_mid_run_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)
    Process.put(:t032_writes, 0)

    assert {:ok, %{statuses: statuses, resume_phases: resume_phases, report: report}} =
             Recovery.plan_run(detail, writer: CountingWriter)

    assert statuses["001"] == :running
    assert resume_phases["001"] == :tasks
    assert %Recovery.Report{} = report

    assert Process.get(:t032_writes) == 0
  end

  test "reconcile_run/2 performs a correction write only when reconciliation actually upgrades a feature to :done" do
    {layout, run_key} = seed_ad_hoc_done_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)
    Process.put(:t032_writes, 0)

    assert {:ok, %{statuses: statuses, resume_phases: resume_phases, report: report}} =
             Recovery.reconcile_run(detail, writer: CountingWriter)

    assert statuses["001"] == :done
    assert resume_phases == %{}
    assert %Recovery.Report{} = report

    assert Process.get(:t032_writes) == 1
  end
end
