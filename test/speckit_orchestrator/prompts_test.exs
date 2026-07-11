defmodule SpeckitOrchestrator.PromptsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Prompts

  test "loads each embedded prompt pack" do
    assert Prompts.load("clarify") =~ "NEEDS HUMAN"
    assert Prompts.load("analyze") =~ "findings"
    assert Prompts.load("converge") =~ "ready for human PR review"
  end

  test "raises on an unknown pack" do
    assert_raise ArgumentError, ~r/no prompt pack/, fn -> Prompts.load("bogus") end
  end
end
