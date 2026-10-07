defmodule Autonomous.SessionExitTest do
  use ExUnit.Case, async: true

  alias Autonomous.SessionExit

  defmodule FakeExit do
    defstruct [:status, :stderr]
  end

  test "extracts stderr from a ProcessExit-shaped term three tuples deep" do
    reason =
      {:initialize_failed, {:channel_exit, {:process_exit, %{status: 1, stderr: "bad json\n"}}}}

    assert %{kind: :start_failed, excerpt: "bad json"} = SessionExit.classify(reason, false)
  end

  test "walks structs" do
    reason = {:shutdown, {:x, %FakeExit{status: 1, stderr: "boom"}}}
    assert %{excerpt: "boom"} = SessionExit.classify(reason, false)
  end

  test "finds stderr in keyword lists" do
    assert %{excerpt: "kw"} = SessionExit.classify([a: 1, stderr: "kw"], false)
  end

  test "falls back to inspect when no stderr" do
    assert %{excerpt: excerpt} = SessionExit.classify({:oops, :nope}, false)
    assert excerpt == "{:oops, :nope}"
  end

  test "bounds excerpt to 2,000 graphemes" do
    big = String.duplicate("é", 5_000)
    assert %{excerpt: e} = SessionExit.classify(%{stderr: big}, false)
    assert String.length(e) == 2_000
  end

  test "collapses whitespace runs and trims" do
    assert %{excerpt: "a b c"} = SessionExit.classify(%{stderr: "  a\n\n b\t c \n"}, true)
  end

  test "empty stderr becomes 'no output captured'" do
    assert %{excerpt: "no output captured"} = SessionExit.classify(%{stderr: " \n "}, false)
    assert %{excerpt: "no output captured"} = SessionExit.classify(%{stderr: ""}, false)
  end

  test "kind follows started?" do
    assert %{kind: :start_failed} = SessionExit.classify(:x, false)
    assert %{kind: :ended_early} = SessionExit.classify(:x, true)
  end

  test "never raises on odd terms" do
    improper = [1 | :tail]
    terms = [improper, self(), fn -> :ok end, make_ref(), {:a, improper}, %{stderr: 5}, nil]

    for t <- terms, started <- [true, false] do
      assert %{excerpt: e} = SessionExit.classify(t, started)
      assert e != ""
    end
  end
end
