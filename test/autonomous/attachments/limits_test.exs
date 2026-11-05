defmodule Autonomous.Attachments.LimitsTest do
  use ExUnit.Case, async: true

  alias Autonomous.Attachments.Limits

  test "count" do
    assert Limits.check_count(10, 10) == :ok
    assert Limits.check_count(11, 10) == {:error, {:too_many_files, 10}}
  end

  test "file" do
    assert Limits.check_file(5, 5) == :ok
    assert Limits.check_file(6, 5) == {:error, {:too_large, 6, 5}}
  end

  test "total" do
    assert Limits.check_total(25, 25) == :ok
    assert Limits.check_total(26, 25) == {:error, {:total_too_large, 26, 25}}
  end

  test "maxima default to Config" do
    assert Limits.check_count(10) == :ok
    assert Limits.check_file(10_000_000) == :ok
    assert {:error, {:too_large, _, 10_000_000}} = Limits.check_file(10_000_001)
    assert Limits.check_total(25_000_000) == :ok
  end
end
