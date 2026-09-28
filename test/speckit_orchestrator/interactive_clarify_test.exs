defmodule SpeckitOrchestrator.InteractiveClarifyTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{InteractiveClarify, NeedsHuman, RunContext}
  alias SpeckitOrchestrator.InteractiveClarify.{AnswerSet, Settings}
  alias SpeckitOrchestrator.NeedsHuman.Question

  describe "Settings.validate/1" do
    test "defaults when given an empty input" do
      assert {:ok, %Settings{enabled?: false, answer_timeout_s: 1_800, max_rounds: 3}} =
               Settings.validate(%{})
    end

    test "accepts a keyword list too" do
      assert {:ok, %Settings{enabled?: true}} = Settings.validate(enabled?: true)
    end

    for bad <- [59, 86_401, "60", 60.0, nil] do
      test "rejects answer_timeout_s #{inspect(bad)}, never clamping" do
        assert Settings.validate(%{answer_timeout_s: unquote(Macro.escape(bad))}) ==
                 {:error, {:invalid_answer_timeout, unquote(Macro.escape(bad))}}
      end
    end

    test "accepts the boundary answer_timeout_s values" do
      assert {:ok, %Settings{answer_timeout_s: 60}} = Settings.validate(%{answer_timeout_s: 60})
      assert {:ok, %Settings{answer_timeout_s: 86_400}} =
               Settings.validate(%{answer_timeout_s: 86_400})
    end

    for bad <- [0, 6, "2", 2.0, nil] do
      test "rejects max_rounds #{inspect(bad)}, never clamping" do
        assert Settings.validate(%{max_rounds: unquote(Macro.escape(bad))}) ==
                 {:error, {:invalid_max_rounds, unquote(Macro.escape(bad))}}
      end
    end

    test "accepts every integer in 1..5 for max_rounds" do
      for n <- 1..5 do
        assert {:ok, %Settings{max_rounds: ^n}} = Settings.validate(%{max_rounds: n})
      end
    end

    test "raises on a non-boolean enabled? — programmer error" do
      assert_raise ArgumentError, fn -> Settings.validate(%{enabled?: "yes"}) end
    end
  end

  describe "Settings.from_context/1" do
    test "nil context falls back to Config defaults" do
      assert {:ok, %Settings{enabled?: false}} = Settings.from_context(nil)
    end

    test "an absent field falls back to Config, a present invalid field still errors" do
      ctx = %RunContext{interactive_clarify: true, clarify_answer_timeout_s: 10}

      assert Settings.from_context(ctx) == {:error, {:invalid_answer_timeout, 10}}
    end

    test "reads every field from a RunContext" do
      ctx = %RunContext{
        interactive_clarify: true,
        clarify_answer_timeout_s: 120,
        clarify_max_rounds: 2
      }

      assert {:ok, %Settings{enabled?: true, answer_timeout_s: 120, max_rounds: 2}} =
               Settings.from_context(ctx)
    end

    test "reads a string-keyed manifest map" do
      map = %{
        "interactive_clarify" => true,
        "clarify_answer_timeout_s" => 300,
        "clarify_max_rounds" => 1
      }

      assert {:ok, %Settings{enabled?: true, answer_timeout_s: 300, max_rounds: 1}} =
               Settings.from_context(map)
    end
  end

  describe "decide/3" do
    setup do
      {:ok, off: %Settings{enabled?: false}, on: %Settings{enabled?: true, max_rounds: 3}}
    end

    test "passes any transition other than {:escalated, :needs_human}", %{on: on} do
      assert InteractiveClarify.decide({:advance, :plan}, on, 0) == :pass
      assert InteractiveClarify.decide({:halted, :critical_finding}, on, 0) == :pass
      assert InteractiveClarify.decide(:done, on, 0) == :pass
    end

    test "mode off always passes, even on the needs-human transition", %{off: off} do
      assert InteractiveClarify.decide({:escalated, :needs_human}, off, 0) == :pass
    end

    test "mode on with rounds left awaits", %{on: on} do
      assert InteractiveClarify.decide({:escalated, :needs_human}, on, 0) == :await
      assert InteractiveClarify.decide({:escalated, :needs_human}, on, 2) == :await
    end

    test "mode on with rounds exhausted escalates by name", %{on: on} do
      assert InteractiveClarify.decide({:escalated, :needs_human}, on, 3) ==
               {:escalated, {:needs_human, :rounds_exhausted}}
    end
  end

  describe "on_exit/1" do
    test "maps every wait exit to its escalation reason" do
      assert InteractiveClarify.on_exit(:answer_timeout) == {:needs_human, :answer_timeout}
      assert InteractiveClarify.on_exit(:breaker) == {:needs_human, :breaker}
      assert InteractiveClarify.on_exit(:drained) == {:needs_human, :drained}
      assert InteractiveClarify.on_exit(:restart) == {:needs_human, :restart}
    end
  end

  describe "AnswerSet.build/2 — numbered" do
    setup do
      questions = [
        %Question{id: "Q1", text: "First?", options: [], recommended: "yes"},
        %Question{id: "Q2", text: "Second?", options: [], recommended: nil}
      ]

      {:ok, questions: questions}
    end

    test "typed answers win over any default", %{questions: questions} do
      assert {:ok, %AnswerSet{answers: %{"Q1" => {:typed, "no"}, "Q2" => {:typed, "sure"}}}} =
               AnswerSet.build({:numbered, questions}, %{"Q1" => "no", "Q2" => "sure"})
    end

    test "a blank answer with a recommended default is recorded as accepted", %{
      questions: questions
    } do
      assert {:ok, %AnswerSet{answers: %{"Q1" => {:default, "yes"}, "Q2" => {:typed, "sure"}}}} =
               AnswerSet.build({:numbered, questions}, %{"Q1" => "", "Q2" => "sure"})
    end

    test "a blank answer with no default is a missing_answer error", %{questions: questions} do
      assert AnswerSet.build({:numbered, questions}, %{"Q1" => "yeah", "Q2" => ""}) ==
               {:error, {:missing_answer, "Q2"}}
    end

    test "a wholly absent answer with no default is a missing_answer error", %{
      questions: questions
    } do
      assert AnswerSet.build({:numbered, questions}, %{"Q1" => "yeah"}) ==
               {:error, {:missing_answer, "Q2"}}
    end
  end

  describe "AnswerSet.build/2 — freeform" do
    test "a typed answer builds a single-entry set" do
      assert {:ok, %AnswerSet{answers: %{"*" => {:typed, "prorate by day"}}}} =
               AnswerSet.build({:freeform, "some question text"}, %{"*" => "prorate by day"})
    end

    test "a blank submission is an empty_answer error" do
      assert AnswerSet.build({:freeform, "text"}, %{"*" => ""}) == {:error, :empty_answer}
      assert AnswerSet.build({:freeform, "text"}, %{}) == {:error, :empty_answer}
    end
  end

  describe "AnswerSet.render/2" do
    test "renders numbered answers with typed and accepted-default markers" do
      set = %AnswerSet{
        answers: %{"Q1" => {:typed, "no"}, "Q2" => {:default, "yes"}}
      }

      rendered = AnswerSet.render(set, 2)

      assert rendered =~ "Operator answers (authoritative, round 2):"
      assert rendered =~ "Q1: no"
      assert rendered =~ "Q2 (accepted recommended): yes"
      assert rendered =~ "Fold every answer into `## Clarifications`"
    end

    test "renders a freeform answer verbatim, without a Qn prefix" do
      set = %AnswerSet{answers: %{"*" => {:typed, "prorate by day"}}}

      rendered = AnswerSet.render(set, 1)

      assert rendered =~ "prorate by day"
      refute rendered =~ "*:"
    end
  end

  test "NeedsHuman.Question struct round-trips through AnswerSet.build/2" do
    {:numbered, [q1]} =
      NeedsHuman.parse_questions("""
      ### Q1: Prorate mid-month changes?
      **Recommended**: yes
      """)

    assert {:ok, %AnswerSet{answers: %{"Q1" => {:default, "yes"}}}} =
             AnswerSet.build({:numbered, [q1]}, %{})
  end
end
