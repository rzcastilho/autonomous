defmodule SpeckitOrchestrator.Store.MigrationsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Migrations

  test "current_version/0 is 2 (019 clean break)" do
    assert Migrations.current_version() == 2
  end

  test "all/0's single entry is version 2 with the refusal description" do
    assert [{2, description, fun}] = Migrations.all()
    assert description =~ "019 clean break"
    assert is_function(fun, 0)
    assert fun.() == {:error, {:incompatible_record, 1}}
  end

  describe "apply_pending/1" do
    test "from a fresh schema (nil) — unreachable in practice, since Store.Boot writes v2 directly without calling apply_pending, but the function itself must not silently succeed past a registered migration" do
      assert Migrations.apply_pending(nil) == {:error, {:incompatible_record, 1}}
    end

    test "from a recorded v1 — the migration refuses, naming the incompatibility (FR-023)" do
      assert Migrations.apply_pending(1) == {:error, {:incompatible_record, 1}}
    end

    test "from the current version (2) — nothing pending, succeeds as a no-op" do
      assert Migrations.apply_pending(2) == :ok
      assert Migrations.apply_pending(Migrations.current_version()) == :ok
    end
  end
end
