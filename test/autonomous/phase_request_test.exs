defmodule Autonomous.PhaseRequestTest do
  use ExUnit.Case, async: true

  alias Autonomous.{Feature, PhaseRequest}
  alias Autonomous.TaskPlan.{Task, TaskPhase}

  # Default `Config.phase_timeout/0` is 50 min → the 032 shell timeouts below.
  @default_timeouts %{
    "BASH_DEFAULT_TIMEOUT_MS" => "1800000",
    "BASH_MAX_TIMEOUT_MS" => "2700000"
  }
  @all_phases [:specify, :plan, :tasks, :analyze, :implement, :clarify, :converge, :describe]

  defp feature do
    %Feature{
      id: "001",
      number: 1,
      slug: "core-ledger",
      path: "/abs/docs/breakdown/001-core-ledger.md"
    }
  end

  test "specify: slash command + breakdown ref, sonnet model, non-interactive Bash" do
    r = PhaseRequest.build(feature(), :specify)
    assert String.starts_with?(r.prompt, "/speckit.specify")
    assert r.prompt =~ "docs/breakdown/001-core-ledger.md"
    assert r.prompt =~ "001"
    assert r.prompt =~ "core-ledger"
    assert r.model == "sonnet"
    assert r.prompt =~ "SPECIFY_FEATURE_DIRECTORY=specs/001-core-ledger"
    assert r.prompt =~ "GIT_BRANCH_NAME=feature/001-core-ledger"

    assert r.prompt =~
             "reuse it (allow existing branch); never create or switch to another branch"

    assert r.cwd == "."
    assert r.max_turns == nil
    # specify runs a Spec Kit script (create-new-feature.sh) → Bash pre-approved.
    assert r.permission_mode == :accept_edits
    assert "Bash" in r.allowed_tools
  end

  test "GIT_BRANCH_NAME pin is specify-only — no other phase's prompt carries it" do
    for phase <- [:plan, :tasks, :analyze, :implement, :clarify, :converge] do
      r = PhaseRequest.build(feature(), phase)
      refute r.prompt =~ "GIT_BRANCH_NAME", "#{phase} prompt should not carry the branch pin"
    end
  end

  test "plan/tasks/converge get non-interactive Bash for their Spec Kit scripts" do
    for phase <- [:plan, :tasks, :converge] do
      r = PhaseRequest.build(feature(), phase)
      assert r.permission_mode == :accept_edits, "#{phase} permission_mode"
      assert "Bash" in r.allowed_tools, "#{phase} allows Bash"
    end
  end

  test "clarify edits the spec but gets no Bash" do
    r = PhaseRequest.build(feature(), :clarify)
    assert r.permission_mode == :accept_edits
    assert "Edit" in r.allowed_tools
    refute "Bash" in r.allowed_tools
  end

  test "clarify: reviewer prompt pack with the NEEDS HUMAN contract, opus model" do
    r = PhaseRequest.build(feature(), :clarify)
    assert r.prompt =~ "clarify reviewer"
    assert r.prompt =~ "## NEEDS HUMAN"
    assert r.prompt =~ "001 core-ledger"
    assert r.model == "opus"
  end

  test "analyze: slash command + JSON schema pack, read-only permissions" do
    r = PhaseRequest.build(feature(), :analyze)
    assert String.starts_with?(r.prompt, "/speckit.analyze")
    assert r.prompt =~ "findings"
    assert r.permission_mode == :plan
    assert r.allowed_tools == ~w(Read Grep Glob)
    assert r.disallowed_tools == ~w(Write Edit Agent Task ScheduleWakeup Monitor)
    assert r.model == "opus"
  end

  test "implement: max_turns + scoped write permissions" do
    r = PhaseRequest.build(feature(), :implement)
    assert r.prompt == "/speckit.implement"
    assert r.max_turns == 200
    assert r.permission_mode == :accept_edits
    assert "Write" in r.allowed_tools
    assert "Bash" in r.allowed_tools
  end

  test "tasks and plan use their slash commands" do
    assert PhaseRequest.build(feature(), :tasks).prompt == "/speckit.tasks"

    # Config ships a default plan_stack, so clear it for the no-stack assertion —
    # restoring the original so we don't pollute other tests' view of :plan_stack.
    original = Application.get_env(:autonomous, :plan_stack)
    Application.put_env(:autonomous, :plan_stack, [])
    on_exit(fn -> Application.put_env(:autonomous, :plan_stack, original) end)

    bare = PhaseRequest.build(feature(), :plan).prompt
    assert String.starts_with?(bare, "/speckit.plan\n\n")

    Application.put_env(:autonomous, :plan_stack, ["Elixir", "Phoenix"])
    stacked = PhaseRequest.build(feature(), :plan).prompt
    assert String.starts_with?(stacked, "/speckit.plan Preferred stack: Elixir, Phoenix. ")
    assert stacked =~ "Feature 001 (core-ledger)"

    # Both carry the completion contract the plan gates check for.
    for prompt <- [bare, stacked] do
      assert prompt =~ "placeholder"
      assert prompt =~ "subagents"
      assert prompt =~ "unfilled"

      # `FakeArtifacts` routes offline e2e fixtures by slash-command substring,
      # testing `specify` before `plan` — any other phase's token in this prompt
      # would silently misroute every one of them.
      refute prompt =~ "/speckit.specify"
      refute prompt =~ "/speckit.tasks"
      refute prompt =~ "/speckit.implement"
    end
  end

  test "converge uses the prompt pack" do
    r = PhaseRequest.build(feature(), :converge)
    assert r.prompt =~ "ready for human PR review"
    assert r.prompt =~ "Feature 001 (core-ledger)"
  end

  test "cwd and session_id options are honored" do
    r = PhaseRequest.build(feature(), :implement, cwd: "/wt/feature-001", session_id: "sess-9")
    assert r.cwd == "/wt/feature-001"
    assert r.session_id == "sess-9"
  end

  test "resume_prompt: non-blank guidance is appended as a trailing section" do
    base = PhaseRequest.build(feature(), :implement)
    r = PhaseRequest.build(feature(), :implement, resume_prompt: "resolved: use integer cents")

    assert r.prompt ==
             base.prompt <> "\n\n---\nOperator guidance (resume): resolved: use integer cents"
  end

  test "resume_prompt: blank/absent guidance leaves the prompt byte-identical" do
    base = PhaseRequest.build(feature(), :implement)

    for blank <- [nil, "", "   ", "\n\t"] do
      r = PhaseRequest.build(feature(), :implement, resume_prompt: blank)
      assert r.prompt == base.prompt, "blank #{inspect(blank)} must not change the prompt"
    end

    # opt entirely absent behaves the same as an explicit nil
    assert PhaseRequest.build(feature(), :implement).prompt == base.prompt
  end

  test "resume_prompt: no other RunRequest field changes with or without it" do
    base = PhaseRequest.build(feature(), :implement, cwd: "/wt", session_id: "sess-1")

    r =
      PhaseRequest.build(feature(), :implement,
        cwd: "/wt",
        session_id: "sess-1",
        resume_prompt: "resolved: use integer cents"
      )

    assert r.model == base.model
    assert r.permission_mode == base.permission_mode
    assert r.allowed_tools == base.allowed_tools
    assert r.disallowed_tools == base.disallowed_tools
    assert r.max_turns == base.max_turns
    assert r.cwd == base.cwd
    assert r.session_id == base.session_id
    refute r.prompt == base.prompt
  end

  describe "clarify_answers option (029)" do
    test "non-blank answers are appended after resume_prompt's section" do
      base = PhaseRequest.build(feature(), :clarify)

      r =
        PhaseRequest.build(feature(), :clarify,
          resume_prompt: "operator note",
          clarify_answers: "---\nOperator answers (authoritative, round 1):\nAnswer text\n"
        )

      assert r.prompt ==
               base.prompt <>
                 "\n\n---\nOperator guidance (resume): operator note" <>
                 "\n\n---\nOperator answers (authoritative, round 1):\nAnswer text\n"
    end

    test "coexists with resume_prompt — both sections appear" do
      r =
        PhaseRequest.build(feature(), :clarify,
          resume_prompt: "operator note",
          clarify_answers: "---\nOperator answers (authoritative, round 1):\nQ1: yes\n"
        )

      assert r.prompt =~ "Operator guidance (resume): operator note"
      assert r.prompt =~ "Operator answers (authoritative, round 1):"
      assert r.prompt =~ "Q1: yes"
    end

    test "blank/absent leaves the prompt byte-identical (mode off, FR-002)" do
      base = PhaseRequest.build(feature(), :clarify)

      for blank <- [nil, "", "   ", "\n\t"] do
        r = PhaseRequest.build(feature(), :clarify, clarify_answers: blank)
        assert r.prompt == base.prompt, "blank #{inspect(blank)} must not change the prompt"
      end

      assert PhaseRequest.build(feature(), :clarify).prompt == base.prompt
    end

    test "only affects the prompt — every other RunRequest field is unchanged" do
      base = PhaseRequest.build(feature(), :clarify)
      r = PhaseRequest.build(feature(), :clarify, clarify_answers: "---\nOperator answers: x\n")

      assert r.model == base.model
      assert r.permission_mode == base.permission_mode
      assert r.allowed_tools == base.allowed_tools
      assert r.disallowed_tools == base.disallowed_tools
      assert r.cwd == base.cwd
    end
  end

  test "plan_stack config feeds the plan prompt when set" do
    original = Application.get_env(:autonomous, :plan_stack)
    Application.put_env(:autonomous, :plan_stack, ["Elixir", "SQLite"])
    on_exit(fn -> Application.put_env(:autonomous, :plan_stack, original) end)
    r = PhaseRequest.build(feature(), :plan)
    assert r.prompt =~ "Elixir, SQLite"
    assert r.prompt =~ "Feature 001"
  end

  describe ":scope option (015 chunking)" do
    test "task-phase scope carries all four FR-005 clauses, appended after the bare command" do
      tp = %TaskPhase{
        ordinal: 3,
        number: "3",
        title: "User Story 1 - Long task lists finish",
        tasks: []
      }

      r = PhaseRequest.build(feature(), :implement, scope: {:task_phase, tp})

      assert String.starts_with?(r.prompt, "/speckit.implement")

      assert r.prompt =~
               ~s(Implement ONLY the tasks in "Phase 3: User Story 1 - Long task lists finish" of tasks.md.)

      assert r.prompt =~
               "Do NOT start, plan, or edit files for tasks belonging to any other phase."

      assert r.prompt =~ "Mark each task as [X] in tasks.md immediately as you complete it"
      assert r.prompt =~ "do not\nbatch this to the end of the session."
      assert r.prompt =~ "completing this phase alone is a"
      assert r.prompt =~ "successful outcome"
    end

    test "sweep scope lists the exact remaining task ids in order" do
      tasks = [
        %Task{id: "T007", text: "Do the thing", complete?: false, line: 10},
        %Task{id: "T012", text: "Do the other thing", complete?: false, line: 20}
      ]

      r = PhaseRequest.build(feature(), :implement, scope: {:sweep, tasks})

      assert String.starts_with?(r.prompt, "/speckit.implement")

      assert r.prompt =~
               "Complete ONLY these remaining unchecked tasks from tasks.md, in this order:"

      assert r.prompt =~ "T007, T012"
      assert r.prompt =~ "Mark each task as [X] in tasks.md immediately as you complete it"
      assert r.prompt =~ "do not\nbatch this to the end of the session."

      assert r.prompt =~
               "Completing exactly these tasks is a successful outcome for this session."
    end

    test "the absent / non-implement scope is byte-identical to today" do
      base = PhaseRequest.build(feature(), :implement)

      assert PhaseRequest.build(feature(), :implement, scope: nil).prompt == base.prompt

      tp = %TaskPhase{ordinal: 1, number: "1", title: "Setup", tasks: []}

      assert PhaseRequest.build(feature(), :tasks, scope: {:task_phase, tp}).prompt ==
               PhaseRequest.build(feature(), :tasks).prompt
    end

    test "a scoped request otherwise matches the unscoped implement request byte-for-byte" do
      tp = %TaskPhase{ordinal: 1, number: "1", title: "Setup", tasks: []}
      base = PhaseRequest.build(feature(), :implement)
      r = PhaseRequest.build(feature(), :implement, scope: {:task_phase, tp})

      assert r.model == base.model
      assert r.max_turns == base.max_turns
      assert r.cwd == base.cwd
      assert r.permission_mode == base.permission_mode
      assert r.allowed_tools == base.allowed_tools
    end
  end

  describe ":containment option (030)" do
    test "default (absent) is strict — byte-identical RunRequest except env markers" do
      for phase <- [:specify, :plan, :tasks, :analyze, :implement, :clarify, :converge, :describe] do
        default = PhaseRequest.build(feature(), phase)
        explicit = PhaseRequest.build(feature(), phase, containment: "strict")

        assert default.prompt == explicit.prompt
        assert default.cwd == explicit.cwd
        assert default.model == explicit.model
        assert default.permission_mode == explicit.permission_mode
        assert default.allowed_tools == explicit.allowed_tools
        assert default.disallowed_tools == explicit.disallowed_tools
        assert default.max_turns == explicit.max_turns

        assert default.metadata["claude"][:env] ==
                 Map.merge(
                   %{
                     "AUTONOMOUS_ORCHESTRATED" => "1",
                     "AUTONOMOUS_CONTAINMENT_PROFILE" => "strict"
                   },
                   @default_timeouts
                 )
      end
    end

    test "permissive: bypass_permissions, full tool set, FR-008 exclusions only" do
      for phase <- [:specify, :plan, :tasks, :analyze, :implement, :clarify, :converge, :describe] do
        r = PhaseRequest.build(feature(), phase, containment: "permissive")

        assert r.permission_mode == :bypass_permissions, "#{phase} permission_mode"

        assert r.allowed_tools ==
                 ~w(Read Write Edit MultiEdit NotebookEdit Bash Grep Glob WebFetch WebSearch),
               "#{phase} allowed_tools"

        assert r.disallowed_tools == ~w(Agent Task ScheduleWakeup Monitor),
               "#{phase} disallowed_tools"

        assert r.metadata["claude"][:env] ==
                 Map.merge(
                   %{
                     "AUTONOMOUS_ORCHESTRATED" => "1",
                     "AUTONOMOUS_CONTAINMENT_PROFILE" => "permissive"
                   },
                   @default_timeouts
                 )
      end
    end

    test "permissive does not change the prompt, cwd, model, max_turns, or session_id" do
      strict = PhaseRequest.build(feature(), :implement, cwd: "/wt", session_id: "s1")

      permissive =
        PhaseRequest.build(feature(), :implement,
          cwd: "/wt",
          session_id: "s1",
          containment: "permissive"
        )

      assert strict.prompt == permissive.prompt
      assert strict.cwd == permissive.cwd
      assert strict.model == permissive.model
      assert strict.max_turns == permissive.max_turns
      assert strict.session_id == permissive.session_id
    end

    test "env markers are present under both profiles for build_remediation/3" do
      strict = PhaseRequest.build_remediation(feature(), "sonnet", prompt: "fix it")

      permissive =
        PhaseRequest.build_remediation(feature(), "sonnet",
          prompt: "fix it",
          containment: "permissive"
        )

      assert strict.metadata["claude"][:env] ==
               Map.merge(
                 %{
                   "AUTONOMOUS_ORCHESTRATED" => "1",
                   "AUTONOMOUS_CONTAINMENT_PROFILE" => "strict"
                 },
                 @default_timeouts
               )

      assert permissive.metadata["claude"][:env] ==
               Map.merge(
                 %{
                   "AUTONOMOUS_ORCHESTRATED" => "1",
                   "AUTONOMOUS_CONTAINMENT_PROFILE" => "permissive"
                 },
                 @default_timeouts
               )

      assert permissive.permission_mode == :bypass_permissions

      assert permissive.allowed_tools ==
               ~w(Read Write Edit MultiEdit NotebookEdit Bash Grep Glob WebFetch WebSearch)
    end

    test "build_remediation/3 strict permissions are unchanged from before 030" do
      r = PhaseRequest.build_remediation(feature(), "sonnet", prompt: "fix it")
      assert r.permission_mode == :accept_edits
      assert r.allowed_tools == ~w(Read Write Edit Bash Grep Glob)
      assert r.disallowed_tools == ~w(Agent Task ScheduleWakeup Monitor)
    end
  end

  describe "build_remediation/3" do
    test "model passed through verbatim (caller-resolved, no re-routing)" do
      r = PhaseRequest.build_remediation(feature(), "opus", prompt: "fix the money type")
      assert r.model == "opus"

      r2 = PhaseRequest.build_remediation(feature(), "sonnet", prompt: "fix the money type")
      assert r2.model == "sonnet"
    end

    test "write-capable, contained permissions — same set as a write phase" do
      r = PhaseRequest.build_remediation(feature(), "sonnet", prompt: "fix it")
      assert r.permission_mode == :accept_edits
      assert r.allowed_tools == ~w(Read Write Edit Bash Grep Glob)
    end

    test "prompt: framing header (feature id/slug + breakdown ref) + operator text verbatim" do
      r =
        PhaseRequest.build_remediation(feature(), "sonnet",
          prompt: "Fix the money-type Critical the analyze gate flagged."
        )

      assert r.prompt =~ "001"
      assert r.prompt =~ "core-ledger"
      assert r.prompt =~ "docs/breakdown/001-core-ledger.md"
      assert r.prompt =~ "Fix the money-type Critical the analyze gate flagged."
    end

    test "no session_id — fresh session" do
      r = PhaseRequest.build_remediation(feature(), "sonnet", prompt: "fix it")
      assert r.session_id == nil
    end
  end

  describe ":background_retry option (032)" do
    test "absent, nil and [] leave the prompt byte-identical" do
      for phase <- [:specify, :plan, :implement, :converge] do
        base = PhaseRequest.build(feature(), phase)
        assert PhaseRequest.build(feature(), phase, background_retry: nil).prompt == base.prompt
        assert PhaseRequest.build(feature(), phase, background_retry: []).prompt == base.prompt
      end
    end

    test "a non-empty list names every command in the retry note" do
      r = PhaseRequest.build(feature(), :implement, background_retry: ["mix test", "npm run e2e"])
      assert r.prompt =~ "Retry note: the previous session"
      assert r.prompt =~ "- mix test\n"
      assert r.prompt =~ "- npm run e2e"
    end

    test "the note is the final block, after resume guidance and clarify answers" do
      r =
        PhaseRequest.build(feature(), :implement,
          resume_prompt: "use the fast path",
          clarify_answers: "---\nOperator answers: yes",
          background_retry: ["mix test"]
        )

      {before_note, _note} = String.split(r.prompt, "\n\n---\nRetry note:") |> List.to_tuple()
      assert before_note =~ "Operator guidance (resume): use the fast path"
      assert before_note =~ "Operator answers: yes"
      assert String.ends_with?(r.prompt, "- mix test")
    end

    test "each command is truncated to 200 chars" do
      long = String.duplicate("x", 500)
      r = PhaseRequest.build(feature(), :implement, background_retry: [long])

      assert r.prompt =~ "- " <> String.duplicate("x", 200) <> "\n" or
               String.ends_with?(r.prompt, "- " <> String.duplicate("x", 200))

      refute r.prompt =~ String.duplicate("x", 201)
    end
  end

  describe "shell timeouts (032, US2)" do
    defp timeouts_in_env(r),
      do: Map.take(r.metadata["claude"][:env], Map.keys(@default_timeouts))

    defp timeouts_in_settings(r),
      do: r.metadata["claude"][:settings] |> Jason.decode!() |> Map.fetch!("env")

    test "every phase x both profiles carries equal values on env and --settings" do
      for phase <- @all_phases, containment <- ["strict", "permissive"] do
        r = PhaseRequest.build(feature(), phase, containment: containment)
        assert timeouts_in_env(r) == @default_timeouts, "#{phase}/#{containment} env"
        assert timeouts_in_settings(r) == @default_timeouts, "#{phase}/#{containment} settings"
      end
    end

    test "build_remediation/3 carries both channels under both profiles" do
      for containment <- ["strict", "permissive"] do
        r = PhaseRequest.build_remediation(feature(), "sonnet", containment: containment)
        assert timeouts_in_env(r) == @default_timeouts
        assert timeouts_in_settings(r) == @default_timeouts
      end
    end

    test "a chunk-sized deadline_ms changes the values; AUTONOMOUS_* markers unchanged" do
      r = PhaseRequest.build(feature(), :implement, deadline_ms: 1_200_000)

      assert timeouts_in_env(r) == %{
               "BASH_DEFAULT_TIMEOUT_MS" => "900000",
               "BASH_MAX_TIMEOUT_MS" => "900000"
             }

      assert timeouts_in_settings(r) == timeouts_in_env(r)
      assert r.metadata["claude"][:env]["AUTONOMOUS_ORCHESTRATED"] == "1"
      assert r.metadata["claude"][:env]["AUTONOMOUS_CONTAINMENT_PROFILE"] == "strict"

      rem = PhaseRequest.build_remediation(feature(), "sonnet", deadline_ms: 1_200_000)
      assert timeouts_in_env(rem) == timeouts_in_env(r)
    end

    test "ClaudeAgentSDK.Options.to_args/1 carries --settings with the JSON" do
      r = PhaseRequest.build(feature(), :implement)
      json = r.metadata["claude"][:settings]

      args = ClaudeAgentSDK.Options.to_args(%ClaudeAgentSDK.Options{settings: json})
      idx = Enum.find_index(args, &(&1 == "--settings"))
      assert idx, "--settings missing from #{inspect(args)}"
      assert Enum.at(args, idx + 1) == json
    end
  end

  describe "headless rule (032, US3)" do
    @rule_marker "This session is headless."

    test "present for task-phase, sweep, whole-list and converge" do
      tp = %TaskPhase{ordinal: 1, number: "1", title: "Setup", tasks: []}
      sweep = [%Task{id: "T001", text: "x", complete?: false, line: 1}]

      for scope <- [{:task_phase, tp}, {:sweep, sweep}, :whole_list] do
        r = PhaseRequest.build(feature(), :implement, scope: scope)
        assert r.prompt =~ "\n\n---\n" <> @rule_marker, "#{inspect(scope)}"
        assert r.prompt =~ "Never use `run_in_background`"
      end

      c = PhaseRequest.build(feature(), :converge)
      [before, after_rule] = String.split(c.prompt, "\n\n---\n" <> @rule_marker)
      refute before =~ @rule_marker
      assert String.ends_with?(String.trim_trailing(c.prompt), "Feature 001 (core-ledger).")
      assert after_rule =~ "Feature 001 (core-ledger)."
    end

    test "absent for scope nil and every other phase" do
      assert PhaseRequest.build(feature(), :implement).prompt == "/speckit.implement"

      for phase <- [:specify, :clarify, :plan, :tasks, :analyze, :describe] do
        refute PhaseRequest.build(feature(), phase).prompt =~ @rule_marker, "#{phase}"
      end

      refute PhaseRequest.build_remediation(feature(), "sonnet", prompt: "x").prompt =~
               @rule_marker
    end
  end

  describe "Monitor exclusion (032, US4)" do
    test "disallowed for every phase and both remediation clauses, both profiles" do
      for containment <- ["strict", "permissive"] do
        for phase <- @all_phases do
          r = PhaseRequest.build(feature(), phase, containment: containment)
          assert "Monitor" in r.disallowed_tools, "#{phase}/#{containment}"
        end

        rem = PhaseRequest.build_remediation(feature(), "sonnet", containment: containment)
        assert "Monitor" in rem.disallowed_tools
      end
    end
  end

  describe "stderr collector (036)" do
    alias Autonomous.SdkProxy
    alias Autonomous.WorkspaceTrust.Collector
    import ExUnit.CaptureLog

    @untrusted ~s(Ignoring 1 permissions.allow entry from x: this workspace has not been trusted. Set projects["/x"].hasTrustDialogAccepted: true)

    test "no collector: env unchanged (byte-identical to pre-036)" do
      r = PhaseRequest.build(feature(), :plan)
      refute Map.has_key?(r.metadata["claude"][:env], SdkProxy.env_key())
    end

    test "collector pid rides in env; proxy strips it and installs the callback" do
      pid = Collector.start()
      r = PhaseRequest.build(feature(), :plan, stderr_collector: pid)
      env = r.metadata["claude"][:env]
      assert env[SdkProxy.env_key()] == SdkProxy.encode(pid)

      opts = SdkProxy.prepare(%ClaudeAgentSDK.Options{env: env})
      refute Map.has_key?(opts.env, SdkProxy.env_key())

      log =
        capture_log(fn ->
          opts.stderr.("harmless")
          opts.stderr.(@untrusted)
        end)

      assert log =~ "CLI stderr: harmless"
      assert log =~ "CLI stderr: " <> String.slice(@untrusted, 0, 30)
      assert Collector.collect(pid) == [@untrusted]
    end

    test "build_remediation carries the collector too" do
      pid = Collector.start()
      r = PhaseRequest.build_remediation(feature(), "sonnet", stderr_collector: pid)
      assert r.metadata["claude"][:env][SdkProxy.env_key()] == SdkProxy.encode(pid)
      Collector.stop(pid)
    end
  end
end
