defmodule SpeckitOrchestrator.ResumeTest do
  # async: false — real-worktree tests point :repo/:worktree_root at throwaway
  # dirs and swap the :jido_claude sdk_module (mirrors run_spec_test.exs /
  # feature_runner_test.exs); every test uses a unique feature id so runs never
  # collide, plus the shared store (StoreCase clears every table + the
  # Store.Health breaker before each test — see test/support/store_case.ex).
  #
  # 018: `resume/2` no longer has a "no store run recorded" fallback (the
  # pre-016 D8 single-feature path, and the file-based `Checkpoint`/
  # `RunManifest` it read). `read_current_run/0` now requires a genuine store
  # run for the configured repo before anything else is resolved — so every
  # fixture here opens one via `Store.Writer.open_run/2` first (`open_run/3,4`
  # below), then seeds a checkpoint into it via `record_phase_attempt/2`
  # (`write_checkpoint/4,5`), mirroring resume_scope_test.exs/resume_run_test.exs.
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{
    Coordinator,
    Feature,
    FeatureRunner,
    Layout,
    RepoIdentity,
    RunContext,
    Worktree
  }

  # Fake SDK — only the branches these tests exercise (analyze -> critical
  # finding). Mirrors feature_runner_test.exs's FakeSDK, trimmed to this
  # feature's scope.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      model = Map.get(options, :model)

      text =
        cond do
          # Mirrors the model a remediation/analyze request carried into the
          # JSON/text response itself (no separate capture channel) — the
          # durable transcript is the only cross-process-safe way to read it
          # back, since the harness call runs inside a spawned runner Task,
          # not the test process.
          String.contains?(prompt, "Remediation for feature") ->
            "Remediation ran with model=#{model}. prompt=#{prompt}"

          String.contains?(prompt, "/speckit.analyze") ->
            # Mirror whether the built prompt carries the appended resume-guidance
            # line (PhaseRequest.append_resume_prompt/2) into the JSON `summary`
            # so tests can assert on it via the durable transcript, without a
            # separate capture channel. analyze is the only phase these tests use
            # for a real FakeSDK run — it has no artifact-gate requirement, unlike
            # :plan/:tasks/:implement.
            note =
              if String.contains?(prompt, "Operator guidance (resume):"),
                do: "guidance-present",
                else: "guidance-absent"

            ~s({"summary":"#{note} model=#{model}","findings":[{"severity":"critical","title":"bad"}]})

          true ->
            "Phase completed."
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
  end

  # Fake SDK for the chunked-implement resume tests (US2) — checks off the
  # scoped task-phase's own task (mirrors chunk_runner_test.exs's FakeSDK) and
  # writes a real source file so the artifact gate sees genuine implementation
  # changes. Dispatching task-phase 1 or 2 is treated as a hard bug (both are
  # already complete in every fixture below) and returned as a genuine,
  # non-transient session error — proof by construction that a redispatch of
  # an already-complete task-phase would fail the run loudly rather than
  # silently passing.
  defmodule ChunkFakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      case Regex.run(~r/Implement ONLY the tasks in "Phase (\d+):/, prompt) do
        [_, n] ->
          if n in illegal_phases() do
            error_messages("illegal redispatch of task-phase #{n}")
          else
            check_off_and_succeed(Map.get(options, :cwd), n)
          end

        nil ->
          success_messages()
      end
    end

    defp illegal_phases,
      do: Application.get_env(:speckit_orchestrator, :chunk_fake_illegal_phases, [])

    defp check_off_and_succeed(cwd, n) when is_binary(cwd) do
      case cwd |> Path.join("specs/**/tasks.md") |> Path.wildcard() |> List.first() do
        nil -> :ok
        path -> check_off(path, cwd, n)
      end

      success_messages()
    end

    defp check_off_and_succeed(_cwd, _n), do: success_messages()

    defp check_off(path, cwd, n) do
      content =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&check_line(&1, n))
        |> Enum.join("\n")

      File.write!(path, content)

      impl_path = Path.join(cwd, "lib/fake_phase_#{n}.ex")
      File.mkdir_p!(Path.dirname(impl_path))
      File.write!(impl_path, "defmodule FakePhase#{n} do\nend\n")
    end

    defp check_line(line, n) do
      if String.contains?(line, "T00#{n} "), do: String.replace(line, "[ ]", "[X]"), else: line
    end

    defp success_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "done",
            num_turns: 3,
            is_error: false,
            total_cost_usd: 0.1,
            usage: %{input_tokens: 0, output_tokens: 0}
          },
          raw: %{}
        }
      ]
    end

    defp error_messages(reason) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{session_id: "s", error: reason, is_error: true, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end
  end

  # 016: a :manifest fake for a test Coordinator that must not durably record
  # its features (avoids bleeding a stray feature into a later whole-run
  # scope restore). Coordinator still dual-writes to the file-based
  # `RunManifest` alongside the store (018) — irrelevant to these tests, which
  # read the store exclusively, but kept to avoid a stray real file write from
  # the blocking Coordinator fixture below.
  defmodule NoopManifest do
    def write(_record), do: :ok
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    # An isolated :autonomous_root per test — `Layout.build/3` (every fixture
    # below builds a real `%Layout{}`) resolves it, and the Coordinator's own
    # RunManifest dual-write lands under it too. Never `~/.autonomous`.
    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
    root = Path.join(System.tmp_dir!(), "resume_manifest_#{System.unique_integer([:positive])}")
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev_autonomous,
        do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev_autonomous),
        else: Application.delete_env(:speckit_orchestrator, :autonomous_root)

      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)
    end)

    :ok
  end

  # Numeric — every real feature id is a numeric string (`Backlog`/
  # `SingleSpec.next_id/1`), and `resolve_identity/3`'s no-store-record
  # fallback (`checkpoint_identity/2`) derives `Feature.number` straight from
  # the id via `String.to_integer/1` when no recorded `number` is available.
  defp unique_id, do: "#{System.unique_integer([:positive, :monotonic])}"

  # spec_number mirrors production's invariant (022): `run_fresh/6` always
  # records a feature's spec_number before its worktree exists, so a resumed
  # feature's store row is never genuinely unallocated. Parsed from `id` when
  # numeric (every real id); left `nil` for a synthetic non-numeric id (e.g.
  # `"other-#{unique_id()}"`), which never gets a real worktree.
  defp feature(id),
    do: %Feature{
      id: id,
      number: System.unique_integer([:positive, :monotonic]),
      slug: "resume-facade",
      path: "#{id}-resume-facade.md",
      spec_number: numeric_spec_number(id)
    }

  defp numeric_spec_number(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp capturing_runner(test_pid) do
    fn feat, notify ->
      send(test_pid, {:runner_called, feat})
      notify.(feat.id, :done, nil)
      :ok
    end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # 019: every run publishes a PR unconditionally on :done — fake just the
  # publisher (network/`gh`) so chunked-resume tests reaching :done don't
  # hang on a real git push to the fixtures' unreachable fake remote.
  defp fake_publisher, do: fn feature, _base -> {:ok, "https://example/pr/#{feature.id}"} end

  defp base_repo do
    repo = Path.join(System.tmp_dir!(), "resume_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    # The 012 facade preflight resolves repository identity from `origin` —
    # every real (non-bare-hermetic) throwaway repo needs one.
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "resume_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  # Points the resume wrapper's opt-less Worktree.locate/create calls (mirrors
  # default_runner/2) at a throwaway repo/worktree_root — run/1-family
  # functions never take :repo/:worktree_root as per-call opts.
  defp point_config_at(repo, root) do
    prev =
      for k <- [:repo, :worktree_root], do: {k, Application.get_env(:speckit_orchestrator, k)}

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

  # ---- store fixtures (018) --------------------------------------------------

  defp layout_for(repo, scope \\ :ad_hoc) do
    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, scope)
    layout
  end

  # A real `%Layout{}` whose `worktree_root` is pinned to `root` — the same
  # `root` a fixture's own direct `Worktree.create(feature, repo:, worktree_root:)`
  # call used, so `resume/2`'s own dispatch (`Worktree.locate/2` via
  # `worktree_create_opts/1`) resolves the SAME worktree path the fixture
  # already created (`Layout.build/3` alone would derive a different
  # `worktree_root` under `Config.autonomous_root/0`).
  defp real_layout(repo, root), do: %{layout_for(repo) | worktree_root: root}

  # A throwaway repo with just an `origin` remote (no worktree is ever
  # created against it — every test using this only injects a fake
  # :runner/:executor). 018 removed resume/2's no-store-run fallback, so
  # `Recovery.reconcile_run/2`'s evidence collection (real git calls against
  # `Config.repo/0`) now always runs, even for these otherwise-hermetic
  # tests — this points it at a disposable directory instead of the actual
  # project checkout.
  defp hermetic_repo do
    repo = Path.join(System.tmp_dir!(), "resume_hermetic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    on_exit(fn -> File.rm_rf(repo) end)
    point_config_at(repo, Path.join(repo, "_wt"))
    {repo, layout_for(repo)}
  end

  defp open_run(
         repo,
         layout,
         features,
         context \\ %RunContext{budget_usd: 100.0}
       ) do
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
        settings: RunContext.to_map(context),
        scope: :ad_hoc,
        layout: layout
      })

    run_key = {repo_id, run_id}

    for %{spec_number: n} = f <- features, is_integer(n) do
      :ok = Writer.record_spec_number(run_key, f.id, n)
    end

    run_key
  end

  defp minimal_attempt(feature_id, phase) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: 1,
      step: 1,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :error,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # A diverted checkpoint (re-runs `phase` itself on resume — the store
  # equivalent of the pre-018 file checkpoint's `last_phase`/`status`).
  # `extra` merges additional checkpoint fields (`implement_chunk`,
  # `analyze_remediation`, a custom `reason`) — the store's own knobs the
  # pre-018 checkpoint carried as top-level keys.
  defp write_checkpoint(run_key, id, phase, status, extra \\ %{}) do
    checkpoint =
      Map.merge(
        %{
          phase: phase,
          last_completed_phase: phase,
          status: status,
          reason: "test fixture",
          session_id: "s1"
        },
        extra
      )

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(id, phase),
        checkpoint: checkpoint
      })

    if status in [:escalated, :halted, :failed] do
      :ok = Writer.record_feature_terminal(run_key, id, status, checkpoint.reason, [])
    end

    :ok
  end

  # 018: durable transcripts live in the store, not `.speckit_logs/` — these
  # read back what `resume/2`'s spawned FeatureRunner recorded, mirroring
  # `write_checkpoint/5`'s own store-backed fixtures.
  defp phase_attempts(run_key, feature_id) do
    {:ok, detail} = Store.run(run_key)
    detail.features |> Enum.find(&(&1.feature_id == feature_id)) |> Map.fetch!(:phase_attempts)
  end

  defp remediation_attempts(run_key, feature_id) do
    {:ok, detail} = Store.run(run_key)

    detail.features
    |> Enum.find(&(&1.feature_id == feature_id))
    |> Map.fetch!(:remediation_attempts)
  end

  defp phase_recorded?(run_key, feature_id, phase),
    do: Enum.any?(phase_attempts(run_key, feature_id), &(&1.phase == phase))

  defp transcript_body!(run_key, feature_id, phase) do
    attempt = Enum.find(phase_attempts(run_key, feature_id), &(&1.phase == phase))
    assert attempt, "no #{phase} phase attempt recorded for #{feature_id}"
    {:ok, %{body: body}} = SpeckitOrchestrator.transcript(attempt.attempt_id)
    body
  end

  # ---- distinct failures, no run started (hermetic) ------------------------

  describe "resume/2 — distinct failures, no run started" do
    test "no checkpoint" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      open_run(repo, layout, [feature(id)])

      me = self()

      assert {:error, :no_checkpoint} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 runner: capturing_runner(me)
               )

      refute_received {:runner_called, _}
    end

    test "no checkpoint on disk still returns {:error, :no_checkpoint}, unchanged" do
      # 018: `resume/2` always requires a store-backed run before anything
      # else — the pre-016 D8 "no manifest anywhere" fallback is gone (a
      # genuinely absent run now returns `{:error, :no_manifest}`, exercised
      # in the "016 whole-run scope restore" describe block below). What this
      # test actually pins is that an id absent from an otherwise-real run
      # still surfaces `:no_checkpoint`, not `:unknown_feature` or a crash.
      {repo, layout} = hermetic_repo()
      open_run(repo, layout, [feature("other-#{unique_id()}")])

      me = self()

      assert {:error, :no_checkpoint} =
               SpeckitOrchestrator.resume("does-not-exist",
                 features: [],
                 runner: capturing_runner(me)
               )

      refute_received {:runner_called, _}
    end

    # 018: `{:error, :corrupt_checkpoint}` is dead in the current
    # implementation — it survives only in `resume/2`'s `@spec` for API
    # compatibility, never actually returned (`grep` confirms no call site
    # produces it). A damaged `speckit_checkpoint` row can no longer be
    # produced by a legitimate write either: Mnesia enforces record arity at
    # write time, unlike the old raw-JSON file this test used to corrupt on
    # disk. That decode branch is covered directly at the unit level in
    # test/speckit_orchestrator/store/records_test.exs — nothing end-to-end
    # can reach it anymore (mirrors resume_run_test.exs's T023 comment for
    # the analogous "corrupt manifest" case).
  end

  # ---- 016 T005: SC-005 no-regression + D8 no-manifest/corrupt fallback ----

  describe "resume/2 — 016 whole-run scope restore, no-regression" do
    # 018 removed the D8 "no readable manifest -> today's single-feature
    # path" fallback entirely (`resume_scope/2` and its file-based
    # `RunManifest.read/0` branch no longer exist — `read_current_run/0`
    # always requires a genuine store run). A store run record damaged
    # enough to trigger `{:error, :corrupt_manifest}` can't be produced by a
    # legitimate write for the same reason `:corrupt_checkpoint` can't (see
    # above) — this test's premise (a hand-corrupted `run.json` silently
    # falling back to single-feature mode) has no store-model equivalent.

    # 016 T006/FR-010a: same live-run refusal resume_run/1 already has
    # (guard_active_run/1, reused unchanged) — a resume/2 that would start a
    # second whole-run Coordinator against the same repo's in-flight store
    # run is refused instead of racing it.
    test "a live unfinished Coordinator refuses resume/2 without :force, and :force proceeds" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      # :manifest fake — a real (unfaked) blocking Coordinator would durably
      # record "999" via its own file-based dual-write, which the force:true
      # resume below would then legitimately restore alongside the target
      # (016's whole-run scope restore, exercised on purpose in
      # resume_scope_test.exs) — irrelevant noise for this test, which is
      # only about the live-run guard/force mechanics.
      {:ok, blocking_pid} =
        Coordinator.start_link(
          features: [feature("999")],
          runner: fn _feature, _notify -> :ok end,
          manifest: NoopManifest,
          name: SpeckitOrchestrator.Coordinator
        )

      me = self()

      assert {:error, {:active_run, ^blocking_pid}} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      refute_received {:runner_called, _}
      assert Process.alive?(blocking_pid)

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [],
                 runner: capturing_runner(me),
                 force: true
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:runner_called, feat}
      assert feat.id == id
    end
  end

  # ---- 026 US2: a worker-only active run guards resume too ------------------

  # Mirrors supersession_drain_test.exs's stub worker — polls the same
  # boundary predicate a real phase/chunk/remediation site would, never
  # killed from outside.
  defp drain_aware_worker(me) do
    send(me, :worker_running)
    wait_for_worker_drain(me)
  end

  defp wait_for_worker_drain(me) do
    if SpeckitOrchestrator.Workers.drain_requested?() do
      send(me, :worker_drained)
    else
      Process.sleep(20)
      wait_for_worker_drain(me)
    end
  end

  describe "resume/2 — 026 worker-only active-run guard" do
    test "refuses with {:error, {:active_run, worker_pid}} when only a worker is alive (no Coordinator), and starts no work (AS1, FR-005, SC-004)" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      {:ok, worker_pid} = SpeckitOrchestrator.Workers.spawn(run_key, id, fn -> drain_aware_worker(me) end)
      assert_receive :worker_running, 2_000
      refute Process.whereis(SpeckitOrchestrator.Coordinator)

      assert {:error, {:active_run, ^worker_pid}} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      refute_received {:runner_called, _}
      assert Process.alive?(worker_pid)

      Process.exit(worker_pid, :kill)
    end

    test ":force drains the worker first, then proceeds (AS3, FR-006)" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      {:ok, worker_pid} = SpeckitOrchestrator.Workers.spawn(run_key, id, fn -> drain_aware_worker(me) end)
      assert_receive :worker_running, 2_000

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [],
                 runner: capturing_runner(me),
                 force: true
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # resume/2's guard drains synchronously before anything else runs, so by
      # the time it returns the worker has already observed the request and
      # exited on its own — never killed from outside.
      assert_received :worker_drained
      refute Process.alive?(worker_pid)
      assert_receive {:runner_called, feat}
      assert feat.id == id
    end

    test "with no worker and no Coordinator, resume proceeds exactly as today (AS4)" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:runner_called, feat}
      assert feat.id == id
    end
  end

  # ---- 029: the awaiting-answers guard (contracts/facade-api.md § Resume guard) --

  describe "resume/2 — 029 awaiting-answers guard" do
    test "refuses with {:error, {:awaiting_answers, id}} without :force, and starts no work" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])

      {:ok, _seq} =
        SpeckitOrchestrator.Store.Writer.record_feature_awaiting(run_key, id, %{
          round: 1,
          max_rounds: 3,
          questions_raw: "## NEEDS HUMAN\n\nwhich timezone?",
          questions: {:freeform, "which timezone?"},
          answer_timeout_s: 1_800
        })

      me = self()

      assert {:error, {:awaiting_answers, ^id}} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      refute_received {:runner_called, _}
    end

    test ":force proceeds even while the feature is recorded :awaiting_answers" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :clarify, :escalated)

      {:ok, _seq} =
        SpeckitOrchestrator.Store.Writer.record_feature_awaiting(run_key, id, %{
          round: 1,
          max_rounds: 3,
          questions_raw: "## NEEDS HUMAN\n\nwhich timezone?",
          questions: {:freeform, "which timezone?"},
          answer_timeout_s: 1_800
        })

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [],
                 runner: capturing_runner(me),
                 force: true
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:runner_called, feat}
      assert feat.id == id
    end
  end

  # ---- identity recovery from checkpoint alone (US1, FR-001..004) ---------

  describe "resume/2 — identity recovery from checkpoint alone" do
    test "reconstructs the feature from checkpoint identity when :features is empty and no explicit feature is supplied" do
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(repo, layout, [
          %Feature{
            id: id,
            number: System.unique_integer([:positive, :monotonic]),
            slug: "widget",
            path: "#{id}-widget.md"
          }
        ])

      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:runner_called, feat}
      assert feat.id == id
      assert feat.slug == "widget"
      assert feat.path == "#{id}-widget.md"
    end

    # Pre-018, "explicit/backlog feature wins over checkpoint identity" only
    # ever demonstrated that via the D8 no-manifest fallback (removed in 018
    # — see the "016 whole-run scope restore" describe block above): with no
    # store run at all, resume/2 built a single-feature ad-hoc scope straight
    # from the explicit `feature`, never consulting any recorded identity.
    # Once every resume always continues a real store run,
    # `find_feature_record/2` requires the id to already be part of that
    # run's recorded feature set — so `merge_resume_target/2`'s "already
    # present" branch always fires (`Enum.any?(scope.features, &(&1.id ==
    # feature.id))` is always true for an id that passed `find_feature_record`)
    # and the STORE's own record, not `resolve_identity/3`'s explicit-wins
    # result, is what actually dispatches. This matches resume_scope_test.exs's
    # "an explicit single-feature :features opt (the console's shape) does
    # not narrow the restored scope" — the same precedence, exercised here via
    # `resolve_identity/3`'s alternate input path. `resolve_identity/3`'s only
    # remaining observable effect for an already-recorded feature is validity:
    # it still succeeds (no `{:unknown_feature, id}`) even when the explicit
    # feature disagrees with the store, but the worktree/slug actually used is
    # the store's.
    test "an explicit feature for the same id resolves identity but does not override the store's own record, once the feature is already part of the run" do
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(repo, layout, [
          %Feature{
            id: id,
            number: System.unique_integer([:positive, :monotonic]),
            slug: "wrong-slug",
            path: "wrong.md"
          }
        ])

      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 runner: capturing_runner(me)
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:runner_called, feat}
      assert feat.id == id
      assert feat.slug == "wrong-slug"
      assert feat.path == "wrong.md"
    end

    test "neither explicit/backlog feature nor checkpoint identity resolves — {:error, {:unknown_feature, id}}, no run started" do
      # 018: identity now comes from the feature's own store row
      # (`FeatureRun.slug`/`.path`, written at `open_run/2` time) instead of
      # an optional checkpoint field — the store-model analogue of the old
      # "old-shape checkpoint carrying no identity" fixture is a feature row
      # whose slug/path were never resolved (Mnesia doesn't validate field
      # types at write time, so this is still legitimately reachable).
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(repo, layout, [
          %Feature{
            id: id,
            number: System.unique_integer([:positive, :monotonic]),
            slug: nil,
            path: nil
          }
        ])

      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      assert {:error, {:unknown_feature, ^id}} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      refute_received {:runner_called, _}
    end

    test "tolerates a missing/unloadable backlog when checkpoint identity is present" do
      id = unique_id()

      # A real repo (so 012's identity preflight resolves) with no breakdown
      # dir at all — best_effort_backlog/0 must still tolerate the unloadable
      # backlog.
      repo = base_repo()
      Application.put_env(:speckit_orchestrator, :repo, repo)

      on_exit(fn -> Application.delete_env(:speckit_orchestrator, :repo) end)

      run_key =
        open_run(repo, layout_for(repo), [
          %Feature{
            id: id,
            number: System.unique_integer([:positive, :monotonic]),
            slug: "widget",
            path: "#{id}-widget.md"
          }
        ])

      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      # No :features opt at all — forces the best-effort load_backlog/0 path,
      # which raises against a repo with no breakdown dir; must not crash
      # resume/2.
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, runner: capturing_runner(me))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:runner_called, feat}
      assert feat.slug == "widget"
    end
  end

  # ---- real restart: worktree reuse + fake SDK ------------------------------

  describe "resume/2 — restarts at the checkpointed phase" do
    test "restarts at the checkpointed phase, not Pipeline.first()" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      refute phase_recorded?(run_key, id, :specify)
      refute phase_recorded?(run_key, id, :clarify)
      refute phase_recorded?(run_key, id, :plan)
      refute phase_recorded?(run_key, id, :tasks)
      assert phase_recorded?(run_key, id, :analyze)
    end
  end

  # ---- 025 US1: parity with resume_run/1's whole-run dispatch ---------------

  describe "resume/2 — 025 checkpoint-first parity with resume_run/1" do
    # SC-002/FR-003: `resume/2`'s single-feature dispatch always resolves the
    # checkpoint's own `phase` directly (`resolve_start_phase/2`'s no-`:from`
    # clause — untouched by 025; see plan.md Project Structure). `resume_run/1`'s
    # whole-run dispatch now consults exactly `resumable_run/0`'s
    # `resume_phases` map (`inject_resume_run_strategy/5` wires it straight
    # into the executor) — asserting the two agree here proves parity without
    # opening a real harness session (zero spend, FR-006), across a trail
    # deliberately behind the checkpoint: the exact shape that diverged before
    # this feature (contracts/reconcile-checkpoint-first.md §4).
    defp assert_resume_phase_parity(checkpoint_phase, last_completed_phase, trail_phase) do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)

      if trail_phase do
        git!(wt.path, [
          "commit",
          "--allow-empty",
          "-q",
          "-m",
          "speckit: #{id} checkpoint after #{trail_phase}"
        ])
      end

      run_key = open_run(repo, real_layout(repo, root), [feature(id)])

      write_checkpoint(run_key, id, checkpoint_phase, :in_progress, %{
        last_completed_phase: last_completed_phase
      })

      assert {:ok, %{resume_phases: resume_phases}} = SpeckitOrchestrator.resumable_run()
      assert resume_phases[id] == checkpoint_phase
    end

    test "case 1 (the defect): checkpoint :implement, trail :tasks — both paths resume at :implement" do
      assert_resume_phase_parity(:implement, :analyze, :tasks)
    end

    test "checkpoint :tasks, trail :specify — two phases behind" do
      assert_resume_phase_parity(:tasks, :plan, :specify)
    end

    test "checkpoint :converge (implement just finished), trail :tasks" do
      assert_resume_phase_parity(:converge, :implement, :tasks)
    end

    test "checkpoint :clarify with no boundary commit at all (trail nil)" do
      assert_resume_phase_parity(:clarify, :specify, nil)
    end
  end

  # ---- operator guidance passthrough (US2) ---------------------------------

  describe "resume/2 — operator guidance passthrough" do
    test "delivers the :prompt guidance note to the resumed phase unchanged" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 prompt: "fixed float"
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      analyze_log = transcript_body!(run_key, id, :analyze)
      assert analyze_log =~ "guidance-present"
    end

    test "delivers :prompt with identity recovered from checkpoint alone (no explicit feature)" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [], owner: me, prompt: "fixed float")

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      analyze_log = transcript_body!(run_key, id, :analyze)
      assert analyze_log =~ "guidance-present"
    end

    test "with no :prompt runs the resumed phase with resume_prompt: nil — no error, no placeholder" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      analyze_log = transcript_body!(run_key, id, :analyze)
      assert analyze_log =~ "guidance-absent"
    end
  end

  # ---- pre-phase remediation passthrough (feature 013) ----------------------

  describe "resume/2 — pre-phase remediation passthrough" do
    test ":remediation_prompt reaches FeatureRunner.run/2 and runs before the target phase" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 remediation_prompt: "Fix the money-type Critical the analyze gate flagged."
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      remediation_log = transcript_body!(run_key, id, :remediation)
      assert remediation_log =~ "Fix the money-type Critical the analyze gate flagged."

      # the target phase still ran, after remediation
      assert phase_recorded?(run_key, id, :analyze)
    end

    test ":remediation_model override applies only to the remediation request — the target phase's own model routing is unchanged" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 remediation_prompt: "Fix it.",
                 remediation_model: "sonnet"
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      remediation_log = transcript_body!(run_key, id, :remediation)
      assert remediation_log =~ "model=sonnet"

      # analyze's own model routing (Config.model_for(:analyze) == "opus") is untouched
      analyze_log = transcript_body!(run_key, id, :analyze)
      assert analyze_log =~ "model=opus"
    end

    test "with no :remediation_prompt, no remediation step runs — byte-identical to a plain resume" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      refute phase_recorded?(run_key, id, :remediation)
    end

    test "FR-010: :prompt and :remediation_prompt are independent — both apply, neither suppresses the other" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 prompt: "fixed float",
                 remediation_prompt: "Fix the money-type Critical the analyze gate flagged."
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      remediation_log = transcript_body!(run_key, id, :remediation)
      assert remediation_log =~ "Fix the money-type Critical the analyze gate flagged."

      # the target phase's own :prompt (feature-004 note) still carries through
      analyze_log = transcript_body!(run_key, id, :analyze)
      assert analyze_log =~ "guidance-present"
    end

    test "an unknown :remediation_model alias returns {:error, {:unknown_model, _}}, no run started" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      assert {:error, {:unknown_model, "not-a-model"}} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 runner: capturing_runner(me),
                 remediation_prompt: "Fix it.",
                 remediation_model: "not-a-model"
               )

      refute_received {:runner_called, _}
    end
  end

  # ---- :from phase override (US3) ------------------------------------------

  describe "resume/2 — :from phase override" do
    test "valid :from overrides the checkpointed phase" do
      # Checkpoint points at :converge (no artifact-gate requirement, like
      # :analyze — FakeSDK writes no real files); :from overrides it back to
      # :analyze. If the override were ignored, the run would start at
      # :converge and complete with FakeSDK's generic "Phase completed." text
      # (no not_ready? signal) straight to :done. Landing on :halted instead
      # proves the run actually started at :analyze, not the checkpoint.
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :converge, :halted)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me, from: :analyze)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      refute phase_recorded?(run_key, id, :specify)
      refute phase_recorded?(run_key, id, :tasks)
      assert phase_recorded?(run_key, id, :analyze)
      # :converge itself is never reached this run (the seeded checkpoint
      # fixture's own :converge phase attempt predates this resume call —
      # `report.halted == [id]` above is what proves the pipeline stopped at
      # :analyze rather than skipping straight to :converge).
    end

    test "invalid :from is rejected with {:error, {:unknown_phase, phase}} and starts no run" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      run_key = open_run(repo, layout, [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      assert {:error, {:unknown_phase, :nope}} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 runner: capturing_runner(me),
                 from: :nope
               )

      refute_received {:runner_called, _}
    end
  end

  # ---- 027 US1: the publish-only continue route ----------------------------

  describe "resume/2 — publish-only continue route" do
    defp parked_publish_failure(run_key, id, branch) do
      pf =
        {:publish_failed, :push_failed,
         %{branch: branch, remote: "origin", output: "stub rejected"}}

      :ok = Writer.record_feature_terminal(run_key, id, :failed, pf)
      :ok = Writer.park_run(run_key, %{stopped_by: id, status: :failed, reason: pf})
      pf
    end

    test "continue_run/1 after a publish park retries only the publish: zero phase sessions, and the row flips back to :done with pr_url" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      f = feature(id)
      branch = Worktree.locate(f).branch

      run_key = open_run(repo, layout, [f])
      parked_publish_failure(run_key, id, branch)

      me = self()

      publisher = fn feature, base ->
        send(me, {:publish, feature.id, base})
        {:ok, "https://example/pr/#{feature.id}"}
      end

      assert {:ok, pid} = SpeckitOrchestrator.continue_run(publisher: publisher, owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # The publish-only route never runs a phase session — it just retries
      # the publish (SC-006).
      assert_receive {:publish, ^id, _base}, 2_000
      assert_receive {:run_complete, report}, 2_000
      assert report.done == [id]
      refute phase_recorded?(run_key, id, :specify)

      {:ok, detail} = Store.run(run_key)
      row = Enum.find(detail.features, &(&1.feature_id == id))
      assert row.status == :done
      assert row.terminal_reason == :done
      assert row.pr_url == "https://example/pr/#{id}"
    end

    test "continue_run/1 with a pr_url already recorded via record_pr/3 never touches the publisher's push/gh path" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      f = feature(id)
      branch = Worktree.locate(f).branch

      run_key = open_run(repo, layout, [f])
      parked_publish_failure(run_key, id, branch)

      # The operator opened the PR by hand while the run sat parked — the
      # run isn't `:in_flight` at this point, so `record_pr/3` needs the
      # explicit `:run_id` (its own `current_run_key()` shortcut only finds
      # an in-flight run).
      {_repo_id, run_id} = run_key
      assert :ok = SpeckitOrchestrator.record_pr(id, "https://example/pr/manual", run_id: run_id)

      me = self()

      # No :publisher seam — exercises the real `publish_feature/3`
      # short-circuit (contracts/publish-outcome.md §1 point 1). This
      # hermetic repo's `origin` is a fake, unreachable URL, so a push
      # attempt would error or hang rather than silently succeed — the run
      # reaching :done proves no push/gh call happened.
      assert {:ok, pid} = SpeckitOrchestrator.continue_run(owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 5_000
      assert report.done == [id]

      {:ok, detail} = Store.run(run_key)
      row = Enum.find(detail.features, &(&1.feature_id == id))
      assert row.pr_url == "https://example/pr/manual"
    end

    test "continue_run/1 with :from on a publish-failed feature refuses with {:error, {:publish_only, id}} and starts no run" do
      id = unique_id()
      {repo, layout} = hermetic_repo()
      f = feature(id)
      branch = Worktree.locate(f).branch

      run_key = open_run(repo, layout, [f])
      parked_publish_failure(run_key, id, branch)

      me = self()

      assert {:error, {:publish_only, ^id}} =
               SpeckitOrchestrator.continue_run(runner: capturing_runner(me), from: :analyze)

      refute_received {:runner_called, _}
    end

    # A second, untouched feature can only observe what it branched *from*
    # via a real worktree (a checkpointed dispatch reuses its own worktree
    # and never re-branches) — so this one test earns the extra real-repo
    # setup the others avoid.
    test "the next feature branches from the parked feature's branch once the publish-only route republishes it" do
      id1 = unique_id()
      id2 = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      f1 = feature(id1)
      f2 = feature(id2)

      {:ok, wt1} = Worktree.create(f1, repo: repo, worktree_root: root)
      File.write!(Path.join(wt1.path, "f1.txt"), "built")
      :ok = Worktree.commit(wt1, "feature 1 work")

      run_key = open_run(repo, real_layout(repo, root), [f1, f2])
      parked_publish_failure(run_key, id1, wt1.branch)

      me = self()

      publisher = fn feature, base ->
        send(me, {:publish, feature.id, base})
        {:ok, "https://example/pr/#{feature.id}"}
      end

      assert {:ok, pid} = SpeckitOrchestrator.continue_run(publisher: publisher, owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:publish, ^id1, _base1}, 2_000

      branch2 = Worktree.locate(f2, repo: repo, worktree_root: root).branch
      assert wait_for_branch(repo, branch2), "feature 2's branch never appeared"

      {parent, 0} = System.cmd("git", ["-C", repo, "merge-base", wt1.branch, branch2])
      {tip1, 0} = System.cmd("git", ["-C", repo, "rev-parse", wt1.branch])
      assert String.trim(parent) == String.trim(tip1)

      # Drain feature 2's real FeatureRunner (FakeSDK) to completion before
      # this test exits — an in-flight Task under RunnerSup outlives
      # `on_exit`'s Coordinator stop and would otherwise still be spending
      # against the shared `Ledger`/store when the next test starts.
      assert_receive {:run_complete, _report}, 30_000
    end
  end

  defp wait_for_branch(_repo, _branch, attempts \\ 100)
  defp wait_for_branch(_repo, _branch, 0), do: false

  defp wait_for_branch(repo, branch, attempts) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        true

      _ ->
        Process.sleep(50)
        wait_for_branch(repo, branch, attempts - 1)
    end
  end

  # ---- integration: real branch-gone / branch-reuse edge cases -------------

  describe "resume/2 — worktree recreation (integration)" do
    @tag :integration
    test "recreates the worktree from the existing branch when previously freed" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      File.write!(Path.join(wt.path, "fixed.txt"), "operator fix")
      git!(wt.path, ["add", "-A"])
      git!(wt.path, ["commit", "-q", "-m", "operator fix"])

      # simulate resolve/1 freeing the worktree; the branch survives
      assert :ok = Worktree.remove(wt)
      refute File.dir?(wt.path)

      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      assert File.read!(Path.join(wt.path, "fixed.txt")) == "operator fix"
      refute phase_recorded?(run_key, id, :specify)
      assert phase_recorded?(run_key, id, :analyze)
    end

    @tag :integration
    test "propagates {:worktree, reason} via a :failed notification when the branch is gone" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      run_key = open_run(repo, real_layout(repo, root), [feature(id)])
      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 5_000
      assert report.failed == [id]

      {out, 0} =
        System.cmd("git", ["-C", repo, "branch", "--list", "feature/#{id}-resume-facade"])

      assert out == ""
    end
  end

  # ---- run-context reapply (US2, FR-006..009) -------------------------------

  describe "resume/2 — run context reapply" do
    setup do
      prev_log_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_log_level) end)
      :ok
    end

    # 019 retired `:pr_workflow`/`:max_concurrency` — `RunContext` carries
    # only the eight remaining run-shaping settings (`run_context_test.exs`),
    # and `resume/2` always dispatches through the single stacked executor
    # path now (`inject_resume_scope_strategy/12`'s own comment: "there is no
    # runner-only alternative left to branch on"). The old "routes a
    # checkpoint recording pr_workflow: true through the PR-workflow path"
    # and "an explicit pr_workflow: false resume opt wins ... resumes via the
    # non-PR path" tests verified exactly the branch that no longer exists —
    # and `:pr_workflow` itself is refused outright as a resume/2 opt now
    # (`retired_settings_test.exs`'s "refuses :pr_workflow"), so neither has a
    # new-model equivalent to rewrite into.

    test "reapplies recorded budget_usd/plan_stack/pr_base/pr_remote over live Config defaults" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)

      run_key =
        open_run(
          repo,
          real_layout(repo, root),
          [feature(id)],
          %RunContext{
            budget_usd: 42.0,
            plan_stack: ["research", "plan"],
            pr_base: "develop",
            pr_remote: "upstream"
          }
        )

      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]
      refute phase_recorded?(run_key, id, :specify)

      # 018: the store no longer round-trips the full run context into every
      # checkpoint write (`FeatureRunner.checkpoint_for/3` only carries
      # phase/status/session/analyze_remediation) — context lives once, at
      # the run level (`speckit_run_settings`), recorded at `open_run` and
      # reapplied via `RunContext.merge/2` on every resume (unit-tested
      # directly in run_context_test.exs). What is left to prove end-to-end
      # here is that `resume/2` continued THIS SAME run — so these are the
      # settings `restore_run_scope/2` actually read back and threaded into
      # `FeatureRunner.run/2` as `:run_context` — not a fresh run seeded
      # from live Config defaults. (The run itself has since drained — a
      # single-feature run closes once its one feature reaches ANY terminal
      # state, halted included — so `Store.current_run_key/1` is no longer
      # `run_key` at this point; `Store.run/1` on the specific `run_key` we
      # opened is the right check.)
      assert {:ok, detail} = Store.run(run_key)
      assert detail.settings["budget_usd"] == 42.0
      assert detail.settings["plan_stack"] == ["research", "plan"]
      assert detail.settings["pr_base"] == "develop"
      assert detail.settings["pr_remote"] == "upstream"
    end

    test "a checkpoint with no context key falls back to live Config for all four settings, succeeds without crashing, and logs the fallen-back settings" do
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(
          repo,
          layout,
          [
            %Feature{
              id: id,
              number: System.unique_integer([:positive, :monotonic]),
              slug: "widget",
              path: "#{id}-widget.md"
            }
          ],
          %RunContext{}
        )

      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, pid} =
                   SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
          assert_receive {:runner_called, _feat}
        end)

      assert log =~ "budget_usd"
      assert log =~ "plan_stack"
      assert log =~ "pr_base"
      assert log =~ "pr_remote"
    end

    test "a checkpoint recording only pr_base (partial context) reapplies that value and falls back + logs for the other three" do
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(
          repo,
          layout,
          [
            %Feature{
              id: id,
              number: System.unique_integer([:positive, :monotonic]),
              slug: "widget",
              path: "#{id}-widget.md"
            }
          ],
          %RunContext{pr_base: "develop"}
        )

      write_checkpoint(run_key, id, :analyze, :halted)

      me = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, pid} =
                   SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
          assert_receive {:runner_called, _feat}
        end)

      refute log =~ "pr_base"
      assert log =~ "budget_usd"
      assert log =~ "plan_stack"
      assert log =~ "pr_remote"
    end

    # ---- 029 US4 (FR-017): interactive-clarify settings ride the same
    # generic `RunContext.merge/2` reapply as every other run-shaping
    # setting above — these close the gap research.md R10 says should hold
    # "for free". ----

    test "a resumed run keeps its recorded interactive-clarify settings (no fallback logged)" do
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(
          repo,
          layout,
          [
            %Feature{
              id: id,
              number: System.unique_integer([:positive, :monotonic]),
              slug: "widget",
              path: "#{id}-widget.md"
            }
          ],
          %RunContext{
            interactive_clarify: true,
            clarify_answer_timeout_s: 300,
            clarify_max_rounds: 4
          }
        )

      write_checkpoint(run_key, id, :analyze, :halted)
      me = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, pid} =
                   SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
          assert_receive {:runner_called, _feat}
        end)

      refute log =~ "interactive_clarify"
      refute log =~ "clarify_answer_timeout_s"
      refute log =~ "clarify_max_rounds"
    end

    test "an explicit override at resume takes precedence over a recorded value (surfaces at preflight)" do
      id = unique_id()
      {repo, layout} = hermetic_repo()

      run_key =
        open_run(
          repo,
          layout,
          [
            %Feature{
              id: id,
              number: System.unique_integer([:positive, :monotonic]),
              slug: "widget",
              path: "#{id}-widget.md"
            }
          ],
          %RunContext{interactive_clarify: true, clarify_max_rounds: 2}
        )

      write_checkpoint(run_key, id, :analyze, :halted)

      # The recorded value (2) is in-range and would preflight clean — an
      # out-of-range EXPLICIT override only surfaces here if it actually won
      # over the recorded one, not the other way around.
      assert {:error, {:preflight, [{:invalid_max_rounds, 99}]}} =
               SpeckitOrchestrator.resume(id, features: [], clarify_max_rounds: 99)
    end
  end

  # ---- checkpoint write failure with new fields (US2, FR-010, SC-005) -------

  describe "checkpoint write with slug/path/run_context present" do
    @tag :integration
    test "an unwritable transcript_root still reaches the run's terminal result" do
      # No store fixture here — `FeatureRunner.run/2` is called directly with
      # no `:run_key`, so every store write inside it is a silent no-op
      # (`record_feature_terminal(nil, ...)`); unaffected by 018.
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)

      prev = Application.get_env(:speckit_orchestrator, :transcript_root)
      Application.put_env(:speckit_orchestrator, :transcript_root, "/proc/nonexistent/deny")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:speckit_orchestrator, :transcript_root, prev),
          else: Application.delete_env(:speckit_orchestrator, :transcript_root)
      end)

      result =
        FeatureRunner.run(feature(id),
          worktree: wt,
          start_phase: :analyze,
          run_context: %RunContext{}
        )

      assert result.feature_id == id
      assert result.status == :halted
    end
  end

  # ---- chunked implement resume (US2, FR-021/022/025/025a) ------------------

  describe "resume/2 — chunked implement resume" do
    setup do
      prev_sdk = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, ChunkFakeSDK)

      on_exit(fn ->
        if prev_sdk,
          do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
          else: Application.delete_env(:jido_claude, :sdk_module)

        Application.delete_env(:speckit_orchestrator, :chunk_fake_illegal_phases)
      end)

      :ok
    end

    # `complete` marks which task-phase numbers start pre-checked (simulating
    # a prior run's committed boundary work, FR-023a) — everything else is
    # seeded incomplete.
    defp chunked_repo(id, phases, complete) do
      repo = base_repo()
      # `Feature.spec_id/1` semantics (022): `feature(id)` carries a numeric
      # `spec_number` equal to `id`, so the real path/branch composition
      # zero-pads it — `SpecDir`'s own candidates are built from that same
      # `spec_id`, not the raw wave-local `id`, so this fixture's directory
      # must match it exactly.
      spec_dir = Path.join(repo, "specs/#{Feature.spec_id(feature(id))}-resume-facade")
      File.mkdir_p!(spec_dir)

      body =
        Enum.map_join(phases, "\n", fn {n, title} ->
          mark = if n in complete, do: "X", else: " "
          "## Phase #{n}: #{title}\n\n- [#{mark}] T00#{n} #{title} task\n"
        end)

      File.write!(Path.join(spec_dir, "tasks.md"), "# Tasks\n\n" <> body)

      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "seed tasks"])
      repo
    end

    defp write_chunk_checkpoint(run_key, id, chunk) do
      write_checkpoint(run_key, id, :implement, :failed, %{implement_chunk: chunk})
    end

    defp attach_chunk_resolved(id, me) do
      handler = "resume-test-chunk-resolved-#{id}"

      :telemetry.attach(
        handler,
        [:speckit, :chunk, :resolved],
        fn _event, _meas, meta, _cfg -> send(me, {:chunk_resolved, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "resumes at the recorded task-phase, never redispatches a completed one, and resets sessions_used to 0" do
      id = unique_id()

      phases = [
        {"1", "Setup"},
        {"2", "Core"},
        {"3", "Widgets"},
        {"4", "Gadgets"},
        {"5", "Polish"}
      ]

      repo = chunked_repo(id, phases, ["1", "2"])
      root = tmp_root()
      point_config_at(repo, root)

      Application.put_env(:speckit_orchestrator, :chunk_fake_illegal_phases, ["1", "2"])

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])

      # sessions_used near the 5-task-phase ceiling (2*5+4 = 14): if `resume/2`
      # did not reset it to 0, dispatching task-phases 3-5 (3 more sessions)
      # would hit the ceiling after task-phase 3 and fail before ever reaching
      # 4 — landing on :done instead proves both that the reset happened and
      # that 1-2 were never redispatched (ChunkFakeSDK fails loudly on either).
      write_chunk_checkpoint(run_key, id, %{
        ordinal: 3,
        number: "3",
        title: "Widgets",
        total: 5,
        sessions_used: 13,
        ceiling: 14,
        scope: :task_phase
      })

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 publisher: fake_publisher()
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.done == [id]
    end

    test ":from_task_phase overrides the recorded checkpoint position" do
      id = unique_id()

      phases = [
        {"1", "Setup"},
        {"2", "Core"},
        {"3", "Widgets"},
        {"4", "Gadgets"},
        {"5", "Polish"}
      ]

      repo = chunked_repo(id, phases, ["1"])
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])

      # The checkpoint records task-phase 4, but the operator overrides back
      # to task-phase 2. If the override were ignored, task-phases 2-3 would
      # never be dispatched (only the sweep would see them, and the sweep's
      # prompt shape doesn't match ChunkFakeSDK's per-task-phase check-off) —
      # the run would fail on unchecked tasks instead of completing.
      write_chunk_checkpoint(run_key, id, %{
        ordinal: 4,
        number: "4",
        title: "Gadgets",
        total: 5,
        sessions_used: 0,
        ceiling: 14,
        scope: :task_phase
      })

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 from_task_phase: 2,
                 publisher: fake_publisher()
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.done == [id]
    end

    test "a renumbered task list (numbers shifted, titles stable) resolves by :title and emits [:speckit, :chunk, :resolved]" do
      id = unique_id()

      # The checkpoint's recorded number ("3") no longer exists anywhere in
      # the current file — task-phases 3-5 were renumbered to 6-8, titles
      # unchanged — forcing the number match to miss and the title match
      # ("Widgets") to resolve it instead.
      phases = [
        {"1", "Setup"},
        {"2", "Core"},
        {"6", "Widgets"},
        {"7", "Gadgets"},
        {"8", "Polish"}
      ]

      repo = chunked_repo(id, phases, ["1", "2"])
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])

      write_chunk_checkpoint(run_key, id, %{
        ordinal: 3,
        number: "3",
        title: "Widgets",
        total: 5,
        sessions_used: 0,
        ceiling: 14,
        scope: :task_phase
      })

      me = self()
      attach_chunk_resolved(id, me)

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 publisher: fake_publisher()
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:chunk_resolved, meta}, 10_000
      assert meta.match_kind == :title
      assert meta.title == "Widgets"
      assert meta.number == "6"

      assert_receive {:run_complete, _report}, 30_000
    end

    test "a retitled-but-renumbered-stable task list resolves by :number — no weak-match telemetry" do
      id = unique_id()

      # Number "3" still exists and is still unique — the title changed
      # ("Widgets" -> "Doohickeys") but that never gets consulted once the
      # number matches (data-model.md §5's fixed number > title > ordinal
      # order).
      phases = [
        {"1", "Setup"},
        {"2", "Core"},
        {"3", "Doohickeys"},
        {"4", "Gadgets"},
        {"5", "Polish"}
      ]

      repo = chunked_repo(id, phases, ["1", "2"])
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])

      write_chunk_checkpoint(run_key, id, %{
        ordinal: 3,
        number: "3",
        title: "Widgets",
        total: 5,
        sessions_used: 0,
        ceiling: 14,
        scope: :task_phase
      })

      me = self()
      attach_chunk_resolved(id, me)

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 publisher: fake_publisher()
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, _report}, 30_000
      refute_received {:chunk_resolved, _meta}
    end
  end

  # ---- analyze auto-remediation budget (feature 017, FR-015) -----------------

  describe "resume/2 — the recorded attempt budget is provenance, never budget" do
    test "a resumed run starts at attempts_used == 0 even though the checkpoint records an exhausted budget" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, _wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      run_key = open_run(repo, real_layout(repo, root), [feature(id)])

      # The prior run spent its whole budget and escalated on a persisting
      # finding. Nothing may read this back as spend (FR-015) — it exists so an
      # operator can see what was already tried (SC-005).
      write_checkpoint(run_key, id, :analyze, :halted, %{
        reason: {:critical_finding, :auto_remediation_exhausted},
        analyze_remediation: %{attempts_used: 2, limit: 2, threshold: "high", enabled: true}
      })

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      # A full, fresh budget of two attempts ran — not zero, and not one.
      assert Enum.map(remediation_attempts(run_key, id), & &1.ordinal) == [1, 2]

      # …and the new run's own provenance replaces the old, still at the limit.
      assert {:ok, checkpoint} = Store.checkpoint(run_key, id)
      assert checkpoint.analyze_remediation.attempts_used == 2
      assert checkpoint.analyze_remediation.limit == 2
    end
  end
end
