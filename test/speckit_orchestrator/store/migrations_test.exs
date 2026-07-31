defmodule SpeckitOrchestrator.Store.MigrationsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Migrations

  test "current_version/0 is 4 (019 clean break + feature_run.pr_url + feature_run.advanced_with_findings)" do
    assert Migrations.current_version() == 4
  end

  test "all/0 is the v2 refusal, the v3 pr_url transform, and the v4 advanced_with_findings transform" do
    assert [{2, v2_description, v2_fun}, {3, v3_description, v3_fun}, {4, v4_description, v4_fun}] =
             Migrations.all()

    assert v2_description =~ "019 clean break"
    assert is_function(v2_fun, 0)
    assert v2_fun.() == {:error, {:incompatible_record, 1}}

    assert v3_description =~ "pr_url"
    assert is_function(v3_fun, 0)

    assert v4_description =~ "advanced_with_findings"
    assert is_function(v4_fun, 0)
  end

  describe "apply_pending/1" do
    test "from a fresh schema (nil) — unreachable in practice, since Store.Boot writes the current version directly without calling apply_pending, but the function itself must not silently succeed past a registered migration" do
      assert Migrations.apply_pending(nil) == {:error, {:incompatible_record, 1}}
    end

    test "from a recorded v1 — the v2 migration refuses, naming the incompatibility (FR-023), and halts before v3 runs" do
      assert Migrations.apply_pending(1) == {:error, {:incompatible_record, 1}}
    end

    test "from the current version — nothing pending, succeeds as a no-op" do
      assert Migrations.apply_pending(Migrations.current_version()) == :ok
      assert Migrations.apply_pending(Migrations.current_version() + 1) == :ok
    end
  end
end
