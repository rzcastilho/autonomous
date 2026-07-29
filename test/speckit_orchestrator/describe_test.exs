defmodule SpeckitOrchestrator.DescribeTest do
  # async: false — mutates the global :transcript_root app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Describe

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
