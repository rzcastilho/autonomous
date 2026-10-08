defmodule Autonomous.UntrustedGateTest do
  # async: false — toggles the global :jido_claude sdk_module.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Autonomous.Actions.{RunAutoRemediation, RunFeaturePhase, RunRemediation}
  alias Autonomous.{Feature, Pipeline}

  @untrusted ~s(Ignoring 6 permissions.allow entries from .claude/settings.json: this workspace has not been trusted. Set projects["/x/repo"].hasTrustDialogAccepted: true in /home/u/.claude.json.)

  # Reports an untrusted-workspace line through the request's stderr callback
  # (exactly what the CLI does), then succeeds.
  defmodule UntrustedSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, opts), do: result(opts, ["noise", Process.get(:line)])

    def result(opts, lines) do
      for l <- lines, is_binary(l), do: opts.stderr.(l)
      success()
    end

    defp success do
      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "ok",
            num_turns: 1,
            duration_ms: 1,
            is_error: false,
            total_cost_usd: 0.0,
            usage: %{input_tokens: 0, output_tokens: 0},
            model: "m"
          },
          raw: %{}
        }
      ]
    end
  end

  defmodule QuietSDK do
    def query(_prompt, opts), do: Autonomous.UntrustedGateTest.UntrustedSDK.result(opts, [])
  end

  # The proxy is the configured `:sdk_module`; fake SDKs slot in behind it.
  setup do
    original = Application.get_env(:autonomous, :sdk_proxy_inner)
    on_exit(fn ->
      if original,
        do: Application.put_env(:autonomous, :sdk_proxy_inner, original),
        else: Application.delete_env(:autonomous, :sdk_proxy_inner)
    end)
  end

  defp use_sdk(mod, line \\ nil) do
    Application.put_env(:autonomous, :sdk_proxy_inner, mod)
    if line, do: Process.put(:line, line)
  end

  defp ctx(containment) do
    %{
      agent: %{
        state: %{
          feature: %Feature{id: "001", number: 1, slug: "s", path: "p.md"},
          worktree: nil,
          layout: nil,
          phase: :analyze,
          session_id: nil,
          ledger: nil,
          cost_total: 0.0,
          history: [],
          resume_phase: nil,
          resume_prompt: nil,
          remediation_prompt: "fix",
          remediation_model: nil,
          containment: containment
        }
      }
    }
  end

  @sites [
    {:feature_phase, &RunFeaturePhase.run/2, %{phase: :converge}},
    {:auto_remediation, &RunAutoRemediation.run/2,
     %{prompt: "p", model: "sonnet", attempt: 1}},
    {:remediation, &RunRemediation.run/2, %{}}
  ]

  for {site, idx} <- Enum.with_index([:feature_phase, :auto_remediation, :remediation]) do
    describe "#{site}" do
      test "strict + observation sets the signal and fails the outcome" do
        {_, run, params} = Enum.at(@sites, unquote(idx))
        use_sdk(UntrustedSDK, @untrusted)
        {:ok, u} = quiet(fn -> run.(params, ctx("strict")) end)

        assert u.last_outcome == :error
        assert u.last_signals.untrusted_workspace == %{workspace: "/x/repo", kinds: ["permissions.allow"]}
        assert u.last_result.untrusted_workspace == u.last_signals.untrusted_workspace
      end

      test "permissive + observation only warns" do
        {_, run, params} = Enum.at(@sites, unquote(idx))
        use_sdk(UntrustedSDK, @untrusted)
        parent = self()

        log =
          capture_log(fn -> send(parent, {:r, run.(params, ctx("permissive"))}) end)

        assert_received {:r, {:ok, u}}
        assert u.last_outcome == :ok
        refute Map.has_key?(u.last_signals, :untrusted_workspace)

        assert log =~
                 "untrusted workspace /x/repo: CLI ignored permissions.allow from the committed pack; continuing under permissive"
      end

      test "no observation: no signal under either profile" do
        {_, run, params} = Enum.at(@sites, unquote(idx))
        use_sdk(QuietSDK)

        for profile <- ["strict", "permissive"] do
          {:ok, u} = quiet(fn -> run.(params, ctx(profile)) end)
          assert u.last_outcome == :ok
          refute Map.has_key?(u.last_signals, :untrusted_workspace)
          assert u.last_result.untrusted_workspace == nil
        end
      end
    end
  end

  defp quiet(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:res, fun.()}) end)
    assert_received {:res, res}
    res
  end

  describe "Pipeline row" do
    @obs %{workspace: "/x/repo", kinds: ["permissions.allow"]}

    test "pipeline gate" do
      assert Pipeline.next(:plan, :error, %{untrusted_workspace: @obs}) ==
               {:failed, {:untrusted_workspace, :plan, @obs}}
    end
  end
end
