defmodule SpeckitOrchestrator.ContainmentTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Containment

  describe "normalize/1" do
    test "accepts the atoms :strict and :permissive" do
      assert Containment.normalize(:strict) == {:ok, "strict"}
      assert Containment.normalize(:permissive) == {:ok, "permissive"}
    end

    test "accepts the strings \"strict\" and \"permissive\"" do
      assert Containment.normalize("strict") == {:ok, "strict"}
      assert Containment.normalize("permissive") == {:ok, "permissive"}
    end

    test "refuses anything else" do
      assert Containment.normalize(:bogus) == {:error, {:invalid_containment_profile, :bogus}}
      assert Containment.normalize("bogus") == {:error, {:invalid_containment_profile, "bogus"}}
      assert Containment.normalize(nil) == {:error, {:invalid_containment_profile, nil}}
    end
  end

  describe "permissive?/1" do
    test "true only for \"permissive\"" do
      assert Containment.permissive?("permissive") == true
    end

    test "false for \"strict\" and nil" do
      refute Containment.permissive?("strict")
      refute Containment.permissive?(nil)
    end
  end

  describe "session_env/1" do
    test "carries the orchestrated marker and the profile" do
      assert Containment.session_env("strict") == %{
               "SPECKIT_ORCHESTRATED" => "1",
               "SPECKIT_CONTAINMENT_PROFILE" => "strict"
             }

      assert Containment.session_env("permissive") == %{
               "SPECKIT_ORCHESTRATED" => "1",
               "SPECKIT_CONTAINMENT_PROFILE" => "permissive"
             }
    end
  end

  describe "pr_note/1" do
    test "exact text for permissive" do
      assert Containment.pr_note("permissive") ==
               "\n\n---\n**Containment: permissive.** This feature was built with relaxed\n" <>
                 "containment: the orchestrator's pack applied no deny list, and every phase\n" <>
                 "had full write, Bash and network access. Review side effects outside the\n" <>
                 "diff (pushes, network calls, writes outside the worktree) accordingly."
    end

    test "empty for strict and nil" do
      assert Containment.pr_note("strict") == ""
      assert Containment.pr_note(nil) == ""
    end
  end

  describe "report_line/1" do
    test "exact text for permissive" do
      assert Containment.report_line("permissive") == "containment: permissive (no pack deny list)"
    end

    test "nil for strict and nil" do
      assert Containment.report_line("strict") == nil
      assert Containment.report_line(nil) == nil
    end
  end
end
