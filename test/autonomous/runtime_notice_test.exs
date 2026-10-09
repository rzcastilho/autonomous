defmodule Autonomous.RuntimeNoticeTest do
  use ExUnit.Case, async: true

  alias Autonomous.RuntimeNotice

  test "inside the container there is no notice" do
    assert RuntimeNotice.container_warning(true) == nil
  end

  test "outside the container the notice states the four required facts (contracts/run-start.md § 4)" do
    text = RuntimeNotice.container_warning(false)

    assert is_binary(text)
    assert text =~ "OUTSIDE the container"
    assert text =~ "full tool access"
    assert text =~ "no in-tree deny list"
    assert text =~ "scripts/autonomous"
    assert text =~ "The run proceeds"
    assert length(String.split(text, "\n")) > 1
  end
end
