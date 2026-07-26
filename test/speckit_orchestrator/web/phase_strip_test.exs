defmodule SpeckitOrchestrator.Web.PhaseStripTest do
  @moduledoc """
  `phase_strip/1`'s chunk sub-label (specs/015-implement-phase-chunking,
  contracts/telemetry-chunk.md §4): the implement cell gains an optional
  task-phase/sweep sub-label, but only when `chunk.scope == :task_phase` or
  `:sweep`. Absent/`nil`/`:whole_list` must render **byte-identical** to the
  pre-015 two-attr `phase_strip/1` (FR-019, SC-005) — `@golden_strip` below is
  that exact pre-015 render, captured before this feature touched the
  component.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.Web.CoreComponents

  @golden_strip "<div class=\"phase-strip\">\n  " <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"specify\" title=\"specify\">\n    specify\n  </span>" <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"clarify\" title=\"clarify\">\n    clarify\n  </span>" <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"plan\" title=\"plan\">\n    plan\n  </span>" <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"tasks\" title=\"tasks\">\n    tasks\n  </span>" <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"analyze\" title=\"analyze\">\n    analyze\n  </span>" <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"implement\" title=\"implement\">\n    implement\n  </span>" <>
                  "<span class=\"phase-cell phase-cell-pending\" data-phase=\"converge\" title=\"converge\">\n    converge\n  </span>\n</div>"

  defp strip(assigns), do: render_component(&CoreComponents.phase_strip/1, assigns)

  test "no chunk attr at all renders byte-identical to the pre-015 strip" do
    assert strip(%{phases: %{}, status: :pending}) == @golden_strip
  end

  test "chunk: nil renders byte-identical to the pre-015 strip" do
    assert strip(%{phases: %{}, status: :pending, chunk: nil}) == @golden_strip
  end

  test "chunk with scope: :whole_list renders byte-identical to the pre-015 strip (FR-019, SC-005)" do
    chunk = %{
      ordinal: nil,
      total: nil,
      title: nil,
      attempt: 1,
      scope: :whole_list,
      sessions_used: 1,
      ceiling: 14,
      remaining: nil,
      outcome: nil
    }

    assert strip(%{phases: %{}, status: :pending, chunk: chunk}) == @golden_strip
  end

  test "chunk with scope: :task_phase adds an ordinal/total/title sub-label to the implement cell only" do
    chunk = %{
      ordinal: 3,
      total: 5,
      title: "User Story 1",
      attempt: 1,
      scope: :task_phase,
      sessions_used: 7,
      ceiling: 14,
      remaining: nil,
      outcome: nil
    }

    html = strip(%{phases: %{}, status: :running, chunk: chunk})

    assert html =~
             ~s(<span class="phase-cell phase-cell-pending" data-phase="implement" title="implement">) <>
               ~s(\n    implement<span class="phase-chunk-sublabel"> 3/5 · User Story 1</span>\n  </span>)

    for phase <- [:specify, :clarify, :plan, :tasks, :analyze, :converge] do
      refute html =~ ~s(data-phase="#{phase}">\n    #{phase}<span)
    end
  end

  test "attempt > 1 appends an (attempt N) suffix to the task-phase sub-label" do
    chunk = %{
      ordinal: 3,
      total: 5,
      title: "User Story 1",
      attempt: 2,
      scope: :task_phase,
      sessions_used: 8,
      ceiling: 14,
      remaining: nil,
      outcome: nil
    }

    html = strip(%{phases: %{}, status: :running, chunk: chunk})
    assert html =~ "3/5 · User Story 1 (attempt 2)"
  end

  test "chunk with scope: :sweep renders \"sweep · N left\"" do
    chunk = %{
      ordinal: nil,
      total: nil,
      title: nil,
      attempt: 1,
      scope: :sweep,
      sessions_used: 12,
      ceiling: 14,
      remaining: 2,
      outcome: nil
    }

    html = strip(%{phases: %{}, status: :running, chunk: chunk})
    assert html =~ "sweep · 2 left"
  end
end
