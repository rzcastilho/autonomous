defmodule Autonomous.ConversationCoverageTest do
  # FR-003: every session-driving site is captured. Two nets — a source guard
  # (a new `run_request` call site fails the build until it opens a
  # conversation) and a behavioural check that drives each site through the
  # real SDK seam with a scripted fake.
  use ExUnit.Case, async: false

  alias Autonomous.{Describe, FakeSdk, Feature, Layout}
  alias Autonomous.Actions.{RunAutoRemediation, RunFeaturePhase, RunRemediation}
  alias Autonomous.Store.Records.ConversationRef

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)

  # Files allowed to call the harness directly. Each must open a conversation.
  @sites ~w(
    lib/autonomous/describe.ex
    lib/autonomous/actions/run_feature_phase.ex
    lib/autonomous/actions/run_auto_remediation.ex
    lib/autonomous/actions/run_remediation.ex
  )

  describe "source guard" do
    test "every harness call site is allowlisted and opens a conversation" do
      hits =
        for path <- Path.wildcard(Path.join(@root, "lib/**/*.ex")),
            src = File.read!(path),
            Regex.match?(~r/Jido\.Harness\.run(_request)?\(/, src),
            do: {Path.relative_to(path, @root), src}

      assert Enum.sort(Enum.map(hits, &elem(&1, 0))) == Enum.sort(@sites),
             "a session-driving call site is missing from the capture allowlist"

      for {path, src} <- hits do
        assert src =~ "ConversationSite.open",
               "#{path} drives a harness session without opening a conversation"
      end
    end
  end

  describe "behavioural" do
    setup %{tmp_dir: root} do
      prev_inner = Application.get_env(:autonomous, :sdk_proxy_inner)
      Application.put_env(:autonomous, :sdk_proxy_inner, FakeSdk)
      FakeSdk.configure(frames: FakeSdk.default_frames("sess-cov"))

      on_exit(fn ->
        FakeSdk.reset()

        if prev_inner,
          do: Application.put_env(:autonomous, :sdk_proxy_inner, prev_inner),
          else: Application.delete_env(:autonomous, :sdk_proxy_inner)
      end)

      layout = %Layout{worktree_root: root, transcript_root: root, in_repo_rel: "docs/breakdown"}
      feature = %Feature{id: "001", number: 1, slug: "s", path: "p.md"}

      state = %{
        feature: feature,
        worktree: nil,
        layout: layout,
        run_key: {"o:repo", "r000001"},
        ledger: nil,
        session_id: nil,
        history: [],
        cost_total: 0.0,
        phase: :clarify,
        resume_phase: nil,
        resume_prompt: nil,
        remediation_prompt: "fix it",
        remediation_model: "sonnet",
        last_signals: %{},
        conversations: []
      }

      %{state: state, layout: layout, feature: feature}
    end

    defp ctx(state), do: %{agent: %{state: state}}

    defp assert_captured([%ConversationRef{status: :captured, path: path} = ref], root) do
      file = Path.join(root, path)
      assert File.regular?(file)
      assert ref.entries >= 4
      assert ref.session_id == "sess-cov"
      lines = file |> File.read!() |> String.split("\n", trim: true)
      assert List.last(lines) =~ "\"end\""
    end

    test "phase session", %{state: state, tmp_dir: root} do
      assert {:ok, %{conversations: refs}} =
               RunFeaturePhase.run(%{phase: :clarify, conversation: [ordinal: 1]}, ctx(state))

      assert_captured(refs, root)
    end

    test "implement chunk (scoped phase session)", %{state: state, tmp_dir: root} do
      state = %{state | phase: :implement}

      assert {:ok, %{conversations: refs}} =
               RunFeaturePhase.run(
                 %{
                   phase: :implement,
                   scope: {:sweep, []},
                   conversation: [kind: :implement_chunk, ordinal: 2]
                 },
                 ctx(state)
               )

      assert_captured(refs, root)
    end

    test "auto-remediation", %{state: state, tmp_dir: root} do
      assert {:ok, %{conversations: refs}} =
               RunAutoRemediation.run(%{prompt: "p", model: "sonnet", attempt: 1}, ctx(state))

      assert_captured(refs, root)
    end

    test "pre-phase remediation", %{state: state, tmp_dir: root} do
      assert {:ok, %{conversations: refs}} = RunRemediation.run(%{}, ctx(state))
      assert_captured(refs, root)
    end

    test "describe", %{state: state, feature: feature, layout: layout, tmp_dir: root} do
      FakeSdk.configure(
        frames: [
          %ClaudeAgentSDK.Message{
            type: :result,
            subtype: :success,
            data: %{
              session_id: "sess-cov",
              result: ~s({"commit_message":"c","pr_title":"t","pr_body":"b"}),
              num_turns: 1,
              duration_ms: 1,
              is_error: false,
              total_cost_usd: 0.0,
              usage: %{input_tokens: 0, output_tokens: 0},
              model: "m"
            },
            raw: %{"type" => "result", "session_id" => "sess-cov", "subtype" => "success"}
          }
        ]
      )

      identity = Autonomous.ConversationSite.identity(state, :describe, kind: :describe)

      assert {{:ok, %{pr_body: "b"}},
              %{refs: [%ConversationRef{status: :captured} = ref], session: session}} =
               Describe.run_captured(feature, %{path: root}, layout, identity)

      assert session.session_id == "sess-cov"
      assert File.regular?(Path.join(root, ref.path))
    end

    test "no store-backed run ⇒ nothing opened, session unchanged", %{state: state} do
      assert {:ok, %{conversations: []}} =
               RunFeaturePhase.run(%{phase: :clarify}, ctx(%{state | run_key: nil}))
    end
  end
end
