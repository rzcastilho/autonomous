defmodule Autonomous.Store.MigrationV8Test do
  use ExUnit.Case, async: true

  alias Autonomous.Store.{Migrations, Records, Schema}

  test "current_version/0 is 8 and the migration is registered" do
    assert Migrations.current_version() == 8
    assert {8, description, fun} = List.last(Migrations.all())
    assert description =~ "speckit_phase_attempt.conversations"
    assert is_function(fun, 0)
  end

  test "conversations is the last phase-attempt attribute and defaults the struct to nil" do
    assert List.last(Schema.table(:speckit_phase_attempt).attributes) == :conversations
    assert %Records.PhaseAttempt{}.conversations == nil
  end

  test "a v7 tuple plus a trailing nil decodes as a pre-040 attempt (conversations: nil)" do
    attrs = Schema.table(:speckit_phase_attempt).attributes
    v7 = Enum.reject(attrs, &(&1 == :conversations))

    tuple =
      List.to_tuple([
        :speckit_phase_attempt
        | Enum.map(v7, fn
            :attempt_id -> {"o:repo", "r1", "001", :plan, 1}
            :run_key -> {"o:repo", "r1"}
            :feature_key -> {"o:repo", "r1", "001"}
            :phase -> :plan
            :ordinal -> 1
            :step -> 1
            :label -> "plan"
            :outcome -> :ok
            :cost_kind -> :actual
            _ -> nil
          end)
      ])

    migrated = Tuple.insert_at(tuple, tuple_size(tuple), nil)

    assert {:ok, %Records.PhaseAttempt{conversations: nil, phase: :plan}} =
             Records.decode(:speckit_phase_attempt, migrated)
  end

  test "a ConversationRef list round-trips through encode/decode" do
    ref = %Records.ConversationRef{
      conversation_id: "c",
      path: "p",
      status: :captured,
      entries: 3,
      bytes: 9,
      outcome: :completed
    }

    attempt = %Records.PhaseAttempt{
      attempt_id: {"o:repo", "r1", "001", :plan, 1},
      run_key: {"o:repo", "r1"},
      feature_key: {"o:repo", "r1", "001"},
      phase: :plan,
      ordinal: 1,
      conversations: [ref]
    }

    assert {:ok, ^attempt} =
             attempt |> Records.encode() |> then(&Records.decode(:speckit_phase_attempt, &1))
  end
end
