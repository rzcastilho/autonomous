defmodule SpeckitOrchestrator.DescribeTest do
  # async: false — mutates the global :transcript_root app env / :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Describe, Feature}

  defmodule EnvCapturingSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, opts) do
      send(self(), {:captured_env, opts.env})

      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-describe-env",
            result: ~s({"commit_message":"c","pr_title":"t","pr_body":"b"}),
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

  defp restore_sdk(nil), do: Application.delete_env(:jido_claude, :sdk_module)
  defp restore_sdk(val), do: Application.put_env(:jido_claude, :sdk_module, val)

  describe "containment env markers (030, T016)" do
    setup do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, EnvCapturingSDK)
      on_exit(fn -> restore_sdk(original) end)
      :ok
    end

    defp feature, do: %Feature{id: "001", number: 1, slug: "s", path: "p.md"}

    test "carries SPECKIT_ORCHESTRATED=1 under strict" do
      assert {:ok, _} = Describe.run(feature(), %{path: "."}, nil, containment: "strict")
      assert_received {:captured_env, env}
      assert env["SPECKIT_ORCHESTRATED"] == "1"
      assert env["SPECKIT_CONTAINMENT_PROFILE"] == "strict"
    end

    test "carries SPECKIT_ORCHESTRATED=1 under permissive" do
      assert {:ok, _} = Describe.run(feature(), %{path: "."}, nil, containment: "permissive")
      assert_received {:captured_env, env}
      assert env["SPECKIT_ORCHESTRATED"] == "1"
      assert env["SPECKIT_CONTAINMENT_PROFILE"] == "permissive"
    end

    test "defaults to strict when no :containment option is given" do
      assert {:ok, _} = Describe.run(feature(), %{path: "."}, nil, [])
      assert_received {:captured_env, env}
      assert env["SPECKIT_CONTAINMENT_PROFILE"] == "strict"
    end
  end

  describe "parse/1" do
    test "recovers a fenced json description" do
      text = """
      Here is the summary.

      ```json
      {"commit_message":"feat(x): add x\\n\\nbody","pr_title":"Add x","pr_body":"## Summary\\n- x"}
      ```
      """

      assert {:ok, d} = Describe.parse(text)
      assert d.commit_message =~ "feat(x): add x"
      assert d.pr_title == "Add x"
      assert d.pr_body =~ "Summary"
    end

    test "recovers a bare trailing json object" do
      text = ~s(prose...\n{"commit_message":"c","pr_title":"t","pr_body":"b"})
      assert {:ok, %{commit_message: "c", pr_title: "t", pr_body: "b"}} = Describe.parse(text)
    end

    test "prefers the last valid object" do
      text =
        ~s({"pr_body":"old","pr_title":"old"}\nrevised\n{"pr_body":"new","pr_title":"new","commit_message":"c"})

      assert {:ok, %{pr_body: "new", pr_title: "new"}} = Describe.parse(text)
    end

    test "missing pr_body is not a valid description" do
      assert {:error, :no_description_json} = Describe.parse(~s({"pr_title":"t"}))
    end

    test "no json at all is an error" do
      assert {:error, :no_description_json} = Describe.parse("just prose, no json")
    end

    test "defaults missing commit_message/pr_title to empty strings" do
      assert {:ok, %{commit_message: "", pr_title: "", pr_body: "b"}} =
               Describe.parse(~s({"pr_body":"b"}))
    end
  end

  # `write_pr/2`/`read_pr/1` deleted (018, FR-037 clean break) — the PR
  # title/body they round-tripped through a file now lives in
  # `feature_run.pr_description`, written by `Store.Writer.record_feature_terminal/5`
  # and covered by `test/speckit_orchestrator/store/writer_test.exs`.
end
