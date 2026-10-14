defmodule Autonomous.StderrBoundTest do
  use ExUnit.Case, async: true

  alias Autonomous.StderrBound

  # Push `lines`, returning {emitted_lines, bound}.
  defp run(bound, lines) do
    Enum.reduce(lines, {[], bound}, fn line, {out, b} ->
      case StderrBound.push(b, line) do
        {:emit, l, b} -> {[l | out], b}
        {:held, b} -> {out, b}
      end
    end)
    |> then(fn {out, b} -> {Enum.reverse(out), b} end)
  end

  defp lines(n), do: Enum.map(1..n//1, &"line #{&1}")

  test "within head: everything emitted, nothing held" do
    {out, b} = run(StderrBound.new(3, 2), lines(3))
    assert out == lines(3)
    assert StderrBound.flush(b) == {0, []}
  end

  test "exactly head + tail: nothing dropped" do
    {out, b} = run(StderrBound.new(3, 2), lines(5))
    assert out == lines(3)
    assert StderrBound.flush(b) == {0, ["line 4", "line 5"]}
  end

  test "head + tail + 1 drops exactly one" do
    {out, b} = run(StderrBound.new(3, 2), lines(6))
    assert out == lines(3)
    assert StderrBound.flush(b) == {1, ["line 5", "line 6"]}
  end

  test "100,000 lines keep 1,000 + 1,000 and drop 98,000" do
    {out, b} = run(StderrBound.new(1000, 1000), lines(100_000))
    assert length(out) == 1000
    assert {98_000, tail} = StderrBound.flush(b)
    assert length(tail) == 1000
    assert hd(tail) == "line 99001"
    assert List.last(tail) == "line 100000"
  end

  test "emitted + held + dropped = pushed" do
    for n <- [0, 1, 4, 5, 6, 40] do
      {out, b} = run(StderrBound.new(2, 3), lines(n))
      {dropped, held} = StderrBound.flush(b)
      assert length(out) + length(held) + dropped == n
    end
  end
end
