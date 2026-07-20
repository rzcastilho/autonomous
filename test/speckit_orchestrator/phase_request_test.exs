defmodule SpeckitOrchestrator.PhaseRequestTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Feature, PhaseRequest}

  defp feature do
    %Feature{id: "001", slug: "core-ledger", path: "/abs/docs/breakdown/001-core-ledger.md"}
  end

  test "specify: slash command + breakdown ref, sonnet model, non-interactive Bash" do
    r = PhaseRequest.build(feature(), :specify)
    assert String.starts_with?(r.prompt, "/speckit.specify")
    assert r.prompt =~ "docs/breakdown/001-core-ledger.md"
    assert r.prompt =~ "001"
    assert r.prompt =~ "core-ledger"
    assert r.model == "sonnet"
    assert r.prompt =~ "SPECIFY_FEATURE_DIRECTORY=specs/001-core-ledger"
    assert r.cwd == "."
    assert r.max_turns == nil
    # specify runs a Spec Kit script (create-new-feature.sh) → Bash pre-approved.
    assert r.permission_mode == :accept_edits
    assert "Bash" in r.allowed_tools
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
    assert r.disallowed_tools == ~w(Write Edit)
    assert r.model == "opus"
  end

  test "implement: max_turns + scoped write permissions" do
    r = PhaseRequest.build(feature(), :implement)
    assert r.prompt == "/speckit.implement"
    assert r.max_turns == 80
    assert r.permission_mode == :accept_edits
    assert "Write" in r.allowed_tools
    assert "Bash" in r.allowed_tools
  end

  test "tasks and plan use their slash commands" do
    assert PhaseRequest.build(feature(), :tasks).prompt == "/speckit.tasks"

    # With no configured stack, plan is the bare slash command (config ships a
    # default plan_stack, so clear it for this assertion — restoring the original
    # so we don't pollute other tests' view of :plan_stack).
    original = Application.get_env(:speckit_orchestrator, :plan_stack)
    Application.put_env(:speckit_orchestrator, :plan_stack, [])
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :plan_stack, original) end)
    assert PhaseRequest.build(feature(), :plan).prompt == "/speckit.plan"
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

  test "plan_stack config feeds the plan prompt when set" do
    original = Application.get_env(:speckit_orchestrator, :plan_stack)
    Application.put_env(:speckit_orchestrator, :plan_stack, ["Elixir", "SQLite"])
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :plan_stack, original) end)
    r = PhaseRequest.build(feature(), :plan)
    assert r.prompt =~ "Elixir, SQLite"
    assert r.prompt =~ "Feature 001"
  end
end
