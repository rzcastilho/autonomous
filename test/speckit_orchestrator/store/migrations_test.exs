defmodule SpeckitOrchestrator.Store.MigrationsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Migrations

  test "current_version/0 is a positive integer" do
    assert Migrations.current_version() > 0
  end

  test "all/0 is empty for the schema this build ships with — nothing to apply yet" do
    assert Migrations.all() == []
  end

  describe "apply_pending/1" do
    test "with no migrations registered, any from_version succeeds as a no-op" do
      assert Migrations.apply_pending(nil) == :ok
      assert Migrations.apply_pending(0) == :ok
      assert Migrations.apply_pending(Migrations.current_version()) == :ok
    end
  end
end
