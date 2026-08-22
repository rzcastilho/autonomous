defmodule SpeckitOrchestrator.ArtifactSubstanceTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.ArtifactSubstance

  @fixtures Path.expand("../fixtures/templates", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # A worktree carrying the plan template at `template_at` (a repo-relative
  # path) and `plan.md` holding `body`. Mirrors what `setup-plan.sh` leaves
  # behind: the template on disk and a copy of it as the artifact.
  defp worktree(body, opts) do
    root =
      Path.join(System.tmp_dir!(), "artifact-substance-#{System.unique_integer([:positive])}")

    spec_dir = Path.join(root, "specs/006-feature")
    File.mkdir_p!(spec_dir)

    case Keyword.get(opts, :template_at, ".specify/templates/plan-template.md") do
      nil ->
        :ok

      rel ->
        path = Path.join(root, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Keyword.get(opts, :template, fixture("plan-template.md")))
    end

    artifact = Path.join(spec_dir, Keyword.get(opts, :leaf, "plan.md"))
    File.write!(artifact, body)
    on_exit(fn -> File.rm_rf(root) end)

    {artifact, root}
  end

  defp verdict(body, opts \\ []) do
    {artifact, root} = worktree(body, opts)
    ArtifactSubstance.verdict(artifact, Keyword.get(opts, :profile, :plan), worktree: root)
  end

  describe "template passthrough" do
    test "an untouched copy of the template is unfilled" do
      assert {:unfilled, families} = verdict(fixture("plan-template.md"))
      assert :template_copy in families
    end

    test "identity survives trailing whitespace differences" do
      assert {:unfilled, families} = verdict(fixture("plan-template.md") <> "\n\n")
      assert :template_copy in families
    end

    test "the template is found under templates/overrides/" do
      assert {:unfilled, families} =
               verdict(fixture("plan-template.md"),
                 template_at: ".specify/templates/overrides/plan-template.md"
               )

      assert :template_copy in families
    end

    test "the template is found under presets/" do
      assert {:unfilled, families} =
               verdict(fixture("plan-template.md"),
                 template_at: ".specify/presets/game/templates/plan-template.md"
               )

      assert :template_copy in families
    end

    test "template identity alone is conclusive, without any other family" do
      body = "# Implementation Plan: Real\n\nThis is a real plan.\n"

      assert {:unfilled, [:template_copy]} = verdict(body, template: body)
    end
  end

  describe "placeholder families" do
    test "two families agree — header plus Structure Decision, no template on disk" do
      body = """
      # Implementation Plan: [FEATURE]

      **Branch**: `006-real` | **Date**: 2026-08-20

      We will ship the archive writer.

      **Structure Decision**: [Document the selected structure and reference the real
      directories captured above]
      """

      assert {:unfilled, families} = verdict(body, template_at: nil)
      assert :header_placeholder in families
      assert :structure_decision_placeholder in families
    end

    test "one stray placeholder in an otherwise real plan is filled" do
      body = """
      # Implementation Plan: Map Package Save and Load

      **Branch**: `006-map-package` | **Date**: [DATE]

      **Structure Decision**: Archive code lands in `packages/sim/src/package/`.

      - [x] **I. Deterministic Simulation** — N/A, no simulation state touched.
      """

      assert ArtifactSubstance.verdict(elem(worktree(body, template_at: nil), 0), :plan) ==
               :filled
    end

    test "prose quoting ACTION REQUIRED outside an HTML comment does not match" do
      body = """
      # Implementation Plan: Map Package Save and Load

      **Branch**: `006-map-package` | **Date**: 2026-08-20

      The reviewer checklist uses the phrase `ACTION REQUIRED` to flag blockers,
      and ACTION REQUIRED items are tracked in the issue tracker.

      **Structure Decision**: Archive code lands in `packages/sim/src/package/`.
      """

      assert verdict(body, template_at: nil) == :filled
    end

    test "a markdown link is not a Structure Decision placeholder" do
      body = """
      # Implementation Plan: [FEATURE]

      **Structure Decision**: [see the tree](#structure)
      """

      assert verdict(body, template_at: nil) == :filled
    end

    test "unchecked gates need at least three boxes and no checked box" do
      unanswered = """
      # Implementation Plan: [FEATURE]

      - [ ] **I. One**
      - [ ] **II. Two**
      - [ ] **III. Three**
      """

      assert {:unfilled, families} = verdict(unanswered, template_at: nil)
      assert :all_gates_unchecked in families

      partly = String.replace(unanswered, "- [ ] **II. Two**", "- [x] **II. Two** — N/A, no UI.")
      assert verdict(partly, template_at: nil) == :filled
    end
  end

  describe "real output" do
    test "the filled-in plan passes" do
      assert verdict(fixture("plan-filled.md")) == :filled
    end

    test "a terse but real plan passes" do
      assert verdict(fixture("plan-terse.md")) == :filled
    end
  end

  describe "profiles and probes" do
    test ":tasks checks template identity only" do
      template = "# Tasks: [FEATURE]\n\n- [ ] T001\n- [ ] T002\n- [ ] T003\n"

      assert {:unfilled, [:template_copy]} =
               verdict(template,
                 leaf: "tasks.md",
                 profile: :tasks,
                 template_at: ".specify/templates/tasks-template.md",
                 template: template
               )
    end

    test "a real all-unchecked tasks.md passes — fresh tasks are legitimately unchecked" do
      body =
        "# Tasks: Map Package\n\n- [ ] T001 write the writer\n- [ ] T002 write the reader\n- [ ] T003 tests\n"

      assert verdict(body,
               leaf: "tasks.md",
               profile: :tasks,
               template_at: ".specify/templates/tasks-template.md",
               template: "# Tasks: [FEATURE]\n\n- [ ] T001\n"
             ) == :filled
    end

    test "an unreadable artifact reads as filled — a broken probe is not evidence" do
      assert ArtifactSubstance.verdict("/nonexistent/plan.md", :plan) == :filled
    end

    test "an unknown profile checks nothing" do
      assert verdict(fixture("plan-template.md"), profile: :specify) == :filled
    end
  end
end
