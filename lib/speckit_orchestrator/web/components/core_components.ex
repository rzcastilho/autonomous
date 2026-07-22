defmodule SpeckitOrchestrator.Web.CoreComponents do
  @moduledoc """
  Shared UI primitives reused across every console view (FR-034): the
  lifecycle status→color palette, the fixed seven-phase strip, the
  cost-breaker gauge, badges, and toast primitives. One palette and one phase
  order (`Pipeline.phases/0`) so status colors read identically in the
  status strip, backlog table, DAG, drawer, and escalations list.
  """

  use Phoenix.Component

  alias SpeckitOrchestrator.Pipeline

  @palette %{
    pending: {"Pending", "#9ca3af"},
    blocked: {"Blocked", "#6b7280"},
    running: {"Running", "#3b82f6"},
    escalated: {"Escalated", "#f59e0b"},
    halted: {"Halted", "#ef4444"},
    failed: {"Failed", "#991b1b"},
    done: {"Done", "#22c55e"}
  }

  @doc "The shared lifecycle status → `{label, color}` palette (FR-034)."
  @spec palette() :: %{atom() => {String.t(), String.t()}}
  def palette, do: @palette

  attr(:status, :atom, required: true, doc: "one of Feature.status/0")

  def status_pill(assigns) do
    {label, color} = Map.get(@palette, assigns.status, {to_string(assigns.status), "#9ca3af"})
    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <span
      class="status-pill"
      data-status={@status}
      style={"background-color: #{@color}20; color: #{@color}; border: 1px solid #{@color};"}
    >
      {@label}
    </span>
    """
  end

  @doc """
  Seven-cell strip in the fixed `Pipeline.phases/0` order. `phases` maps
  `phase => %{state: :pending | :active | :completed, ...}`; missing entries
  render as `:pending`. `status` further distinguishes the active cell when
  the feature has diverted (running vs escalated vs halted vs failed —
  FR-008).
  """
  attr(:phases, :map, required: true)
  attr(:status, :atom, default: :pending)

  def phase_strip(assigns) do
    assigns = assign(assigns, :ordered, Pipeline.phases())

    ~H"""
    <div class="phase-strip">
      <span
        :for={phase <- @ordered}
        class={"phase-cell phase-cell-#{phase_cell_state(Map.get(@phases, phase), @status)}"}
        data-phase={phase}
        title={phase}
      >
        {phase}
      </span>
    </div>
    """
  end

  defp phase_cell_state(nil, _status), do: "pending"
  defp phase_cell_state(%{state: :completed}, _status), do: "completed"

  defp phase_cell_state(%{state: :active}, status) when status in [:escalated, :halted, :failed],
    do: to_string(status)

  defp phase_cell_state(%{state: :active}, _status), do: "active"
  defp phase_cell_state(_cell, _status), do: "pending"

  @doc """
  Cost-breaker gauge (`Ledger.snapshot/1` shape): fill = `(committed +
  reserved) / budget`, fill color signals proximity, `tripped?` shows the
  armed/tripped indicator (FR-004, SC-007).
  """
  attr(:committed, :float, default: 0.0)
  attr(:reserved, :float, default: 0.0)
  attr(:budget, :float, default: 0.0)
  attr(:tripped?, :boolean, default: false)

  def cost_gauge(assigns) do
    fill = gauge_fill(assigns.committed, assigns.reserved, assigns.budget)

    assigns =
      assign(assigns,
        fill: fill,
        fill_color: gauge_color(fill, assigns.tripped?),
        spent_label: money(assigns.committed + assigns.reserved),
        budget_label: money(assigns.budget)
      )

    ~H"""
    <div class="cost-gauge" role="meter" aria-valuenow={@fill} aria-valuemin="0" aria-valuemax="100">
      <div class="cost-gauge-fill" style={"width: #{@fill}%; background-color: #{@fill_color};"}></div>
      <span class="cost-gauge-label" data-tripped={@tripped?}>
        ${@spent_label} / ${@budget_label} ({if @tripped?, do: "tripped", else: "armed"})
      </span>
    </div>
    """
  end

  defp gauge_fill(_committed, _reserved, budget) when budget <= 0, do: 100.0

  defp gauge_fill(committed, reserved, budget),
    do: min(100.0, (committed + reserved) / budget * 100.0)

  defp gauge_color(_fill, true), do: "#ef4444"
  defp gauge_color(fill, _tripped?) when fill >= 90, do: "#ef4444"
  defp gauge_color(fill, _tripped?) when fill >= 70, do: "#f59e0b"
  defp gauge_color(_fill, _tripped?), do: "#22c55e"

  defp money(amount), do: :erlang.float_to_binary(amount * 1.0, decimals: 2)

  @doc "Render an amount (or `nil`) as a fixed `$0.00`-style string, used by the backlog table, drawer, and run report."
  @spec format_money(number() | nil) :: String.t()
  def format_money(nil), do: money(0.0)
  def format_money(amount) when is_number(amount), do: money(amount)

  @doc "Render an elapsed millisecond duration (or `nil` before a feature starts) as `Mm Ss`."
  @spec format_elapsed(non_neg_integer() | nil) :: String.t()
  def format_elapsed(nil), do: "—"

  def format_elapsed(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}m #{seconds}s"
  end

  attr(:text, :string, required: true)
  attr(:variant, :atom, default: :neutral)

  def badge(assigns) do
    ~H"""
    <span class={"badge badge-#{@variant}"}>{@text}</span>
    """
  end

  attr(:id, :string, required: true)
  attr(:kind, :atom, default: :info)
  attr(:message, :string, required: true)

  def toast(assigns) do
    ~H"""
    <div id={@id} class={"toast toast-#{@kind}"} role="status">
      {@message}
    </div>
    """
  end
end
