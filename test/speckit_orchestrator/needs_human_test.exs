defmodule SpeckitOrchestrator.NeedsHumanTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.NeedsHuman
  alias SpeckitOrchestrator.NeedsHuman.Question

  describe "present?/1 (moved regex, SC-003)" do
    test "true for the heading on its own line" do
      assert NeedsHuman.present?("# 001\n\n## NEEDS HUMAN\n\nmonth-end proration is ambiguous\n")
    end

    test "false when the marker is only mentioned in prose" do
      refute NeedsHuman.present?("No `## NEEDS HUMAN` — nothing material left")
    end

    test "false for nil" do
      refute NeedsHuman.present?(nil)
    end

    test "false for an empty string" do
      refute NeedsHuman.present?("")
    end

    test "requires the heading text on its own line" do
      refute NeedsHuman.present?("## NEEDS HUMANITY\n")
    end
  end

  describe "extract/1 (moved from EscalationsLive.extract_needs_human/1)" do
    test "nil when the marker is absent" do
      assert NeedsHuman.extract("# spec\n\nnothing here\n") == nil
    end

    test "nil for nil input" do
      assert NeedsHuman.extract(nil) == nil
    end

    test "the block up to the next heading, trimmed" do
      text = """
      # spec

      ## NEEDS HUMAN

      which timezone?

      ## Clarifications
      answered stuff
      """

      assert NeedsHuman.extract(text) == "which timezone?"
    end

    test "the block to EOF when there is no following heading" do
      text = "# spec\n\n## NEEDS HUMAN\n\nwhich one?\n"

      assert NeedsHuman.extract(text) == "which one?"
    end
  end

  describe "parse_questions/1 — numbered format" do
    test "parses a well-formed block with Options and Recommended" do
      block = """
      ### Q1: Does a mid-month plan change prorate the current period?
      **Context**: Decides whether ledger entries split at the change date.
      **Options**: A) Prorate by day · B) Apply from next period · C) Charge the higher plan for the whole period
      **Recommended**: B — no split entries, simplest statement

      ### Q2: Which timezone anchors the billing day?
      **Context**: Affects month boundaries.
      **Recommended**: UTC
      """

      assert {:numbered, [q1, q2]} = NeedsHuman.parse_questions(block)

      assert %Question{
               id: "Q1",
               text: "Does a mid-month plan change prorate the current period?",
               context: "Decides whether ledger entries split at the change date.",
               options: [
                 "A) Prorate by day",
                 "B) Apply from next period",
                 "C) Charge the higher plan for the whole period"
               ],
               recommended: "B — no split entries, simplest statement"
             } = q1

      assert %Question{
               id: "Q2",
               text: "Which timezone anchors the billing day?",
               context: "Affects month boundaries.",
               options: [],
               recommended: "UTC"
             } = q2
    end

    test "options split on bullet lines when there is no interpunct" do
      block = """
      ### Q1: Which plan applies?
      **Options**:
      - Basic
      - Pro
      **Recommended**: Pro
      """

      assert {:numbered, [%Question{options: ["Basic", "Pro"]}]} =
               NeedsHuman.parse_questions(block)
    end

    test "falls back to freeform on non-contiguous ids" do
      block = """
      ### Q1: First?
      **Recommended**: yes

      ### Q3: Third?
      **Recommended**: no
      """

      assert {:freeform, ^block} = NeedsHuman.parse_questions(block)
    end

    test "falls back to freeform when an item has neither Options nor Recommended" do
      block = """
      ### Q1: First?
      **Context**: just context, no way to answer

      ### Q2: Second?
      **Recommended**: yes
      """

      assert {:freeform, ^block} = NeedsHuman.parse_questions(block)
    end

    test "falls back to freeform when text sits before ### Q1" do
      block = """
      Some preamble the reviewer left in.

      ### Q1: First?
      **Recommended**: yes
      """

      assert {:freeform, ^block} = NeedsHuman.parse_questions(block)
    end

    test "never returns a partial parse — one malformed item freeforms the whole block" do
      block = """
      ### Q1: First?
      **Recommended**: yes

      ### Q2: Second?
      **Context**: no options, no recommended
      """

      assert {:freeform, ^block} = NeedsHuman.parse_questions(block)
    end
  end

  describe "parse_questions/1 — freeform / empty" do
    test "empty block gives {:freeform, \"\"}" do
      assert NeedsHuman.parse_questions("") == {:freeform, ""}
    end

    test "whitespace-only block gives {:freeform, \"\"}" do
      assert NeedsHuman.parse_questions("   \n\n  ") == {:freeform, ""}
    end

    test "nil is treated as empty" do
      assert NeedsHuman.parse_questions(nil) == {:freeform, ""}
    end

    test "plain prose with no ### Qn headings is freeform verbatim" do
      block = "Does the operator want prorated billing or not? Please advise.\n"
      assert NeedsHuman.parse_questions(block) == {:freeform, block}
    end
  end
end
