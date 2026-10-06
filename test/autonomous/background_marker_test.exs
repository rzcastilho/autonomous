defmodule Autonomous.BackgroundMarkerTest do
  use ExUnit.Case, async: true

  alias Autonomous.BackgroundMarker

  @path "Output is being written to: /tmp/claude-1000/tasks/b1x9.output"

  test ":timeout marker parses task id and output path" do
    out =
      "Command did not complete within its 600s timeout and was moved to the background (ID: b1x9). " <>
        @path <> "."

    assert {:ok,
            %{mode: :timeout, task_id: "b1x9", output_path: "/tmp/claude-1000/tasks/b1x9.output"}} =
             BackgroundMarker.parse(out)
  end

  test ":message marker" do
    out = "Command was moved to the background (ID: bq7). " <> @path

    assert {:ok,
            %{mode: :message, task_id: "bq7", output_path: "/tmp/claude-1000/tasks/b1x9.output"}} =
             BackgroundMarker.parse(out)
  end

  test ":manual marker strips trailing period from id" do
    out = "Command was manually backgrounded by user with ID: bm3. " <> @path

    assert {:ok, %{mode: :manual, task_id: "bm3"}} = BackgroundMarker.parse(out)
  end

  test ":explicit marker" do
    out = "Command running in background with ID: be5. " <> @path

    assert {:ok, %{mode: :explicit, task_id: "be5", output_path: path}} =
             BackgroundMarker.parse(out)

    assert path == "/tmp/claude-1000/tasks/b1x9.output"
  end

  test "marker without an output path yields a nil path" do
    assert {:ok, %{task_id: "b2", output_path: nil}} =
             BackgroundMarker.parse("Command was moved to the background (ID: b2)")
  end

  test "output path trailing period is stripped" do
    {:ok, %{output_path: path}} =
      BackgroundMarker.parse(
        "Command was moved to the background (ID: b2). Output is being written to: /x/y.out."
      )

    assert path == "/x/y.out"
  end

  test "list-of-content-blocks output is flattened" do
    blocks = [
      %{"type" => "text", "text" => "Command was moved to the background (ID: bl1)."},
      %{"type" => "text", "text" => @path}
    ]

    assert {:ok, %{task_id: "bl1", output_path: "/tmp/claude-1000/tasks/b1x9.output"}} =
             BackgroundMarker.parse(blocks)
  end

  test "non-text and unrelated output returns :none" do
    assert BackgroundMarker.parse(nil) == :none
    assert BackgroundMarker.parse(%{"a" => 1}) == :none
    assert BackgroundMarker.parse([%{"type" => "image"}]) == :none
    assert BackgroundMarker.parse("12 tests, 0 failures") == :none
    assert BackgroundMarker.parse("") == :none
  end

  test "explicit_call?/1 is true only for run_in_background: true" do
    assert BackgroundMarker.explicit_call?(%{"run_in_background" => true})
    refute BackgroundMarker.explicit_call?(%{"run_in_background" => false})
    refute BackgroundMarker.explicit_call?(%{"run_in_background" => "true"})
    refute BackgroundMarker.explicit_call?(%{"command" => "ls"})
    refute BackgroundMarker.explicit_call?(nil)
  end
end
