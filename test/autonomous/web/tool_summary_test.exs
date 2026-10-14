defmodule Autonomous.Web.ToolSummaryTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.ToolSummary

  test "known tools" do
    assert ToolSummary.summary("Bash", %{"command" => "mix test"}) == "Bash(mix test)"
    assert ToolSummary.summary("Read", %{"file_path" => "/a/b.ex"}) == "Read(/a/b.ex)"
    assert ToolSummary.summary("Write", %{"file_path" => "/a"}) == "Write(/a)"
    assert ToolSummary.summary("Edit", %{"file_path" => "/a"}) == "Edit(/a)"

    assert ToolSummary.summary("NotebookEdit", %{"notebook_path" => "/n.ipynb"}) ==
             "NotebookEdit(/n.ipynb)"

    assert ToolSummary.summary("Glob", %{"pattern" => "lib/**"}) == "Glob(lib/**)"
    assert ToolSummary.summary("Grep", %{"pattern" => "foo"}) == "Grep(foo)"
    assert ToolSummary.summary("Skill", %{"skill" => "speckit-plan"}) == "Skill(speckit-plan)"
  end

  test "multi-line command is ellipsized" do
    assert ToolSummary.summary("Bash", %{"command" => "mix test\nmix format"}) ==
             "Bash(mix test …)"
  end

  test "caps long text at 200 chars" do
    s = ToolSummary.summary("Bash", %{"command" => String.duplicate("a", 500)})
    assert s == "Bash(" <> String.duplicate("a", 200) <> ")"
  end

  test "unknown tool uses first string by sorted key" do
    assert ToolSummary.summary("Mystery", %{"b" => 1, "a" => "x", "c" => "y"}) == "Mystery(x)"
    assert ToolSummary.summary("Mystery", %{"b" => 1, "c" => "y"}) == "Mystery(y)"
  end

  test "empty or non-string input gives the name only" do
    assert ToolSummary.summary("Mystery", %{}) == "Mystery"
    assert ToolSummary.summary("Mystery", %{"a" => 1}) == "Mystery"
    assert ToolSummary.summary("Bash", %{}) == "Bash"
    assert ToolSummary.summary("Bash", nil) == "Bash"
    assert ToolSummary.summary("Bash", %{"command" => ""}) == "Bash"
  end

  test "nil name" do
    assert ToolSummary.summary(nil, %{}) == "tool"
    assert ToolSummary.summary(nil, %{"a" => "x"}) == "tool(x)"
  end
end
