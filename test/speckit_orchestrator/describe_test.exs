defmodule SpeckitOrchestrator.DescribeTest do
  use ExUnit.Case, async: true

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

  describe "write_pr/2 + read_pr/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "desc_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:speckit_orchestrator, :transcript_root)
      Application.put_env(:speckit_orchestrator, :transcript_root, root)

      on_exit(fn ->
        File.rm_rf(root)
        if prev, do: Application.put_env(:speckit_orchestrator, :transcript_root, prev)
      end)

      :ok
    end

    test "round-trips the PR title/body under the transcript dir" do
      assert :ok = Describe.write_pr("001", %{pr_title: "T", pr_body: "B"})
      assert {:ok, %{pr_title: "T", pr_body: "B"}} = Describe.read_pr("001")
    end

    test "read_pr is :error when absent" do
      assert :error = Describe.read_pr("999")
    end
  end
end
