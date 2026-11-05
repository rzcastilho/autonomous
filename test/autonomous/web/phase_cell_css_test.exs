defmodule Autonomous.Web.PhaseCellCssTest do
  use ExUnit.Case, async: true

  @css Path.expand("../../../priv/static/assets/console.css", __DIR__)

  # The implement chunk sublabel is invisible (transparent, 7px high) but its nowrap
  # text still counted toward the table cell's auto width, so the Progress column —
  # and the `.backlog-scroll` wrapper — grew horizontally once a run reached implement.
  # CSS cannot be measured in ExUnit, so pin the declaration that prevents it.
  test ".phase-cell has inline-size containment so sublabel text cannot widen the column" do
    css = File.read!(@css)

    [_, rule] = Regex.run(~r/\n\.phase-cell \{(.*?)\n\}/s, css)

    assert rule =~ ~r/contain:\s*inline-size/
  end
end
