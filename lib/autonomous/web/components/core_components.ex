defmodule Autonomous.Web.CoreComponents do
  @moduledoc """
  Shared UI primitives reused across every console view (FR-034): the
  lifecycle status label/class transport, the fixed seven-phase strip,
  badges, and toast primitives. One label map and one
  phase order (`Pipeline.phases/0`) so status colors read identically in the
  status strip, backlog table, DAG, drawer, and escalations list — the color
  itself lives once, in `priv/static/assets/console.css`'s `[data-status]`
  rules (docs/design-constitution.md §II).
  """

  use Phoenix.Component

  alias Autonomous.Pipeline

  @labels %{
    pending: "Pending",
    blocked: "Blocked",
    running: "Running",
    escalated: "Escalated",
    halted: "Halted",
    failed: "Failed",
    done: "Done",
    never_started: "Never started",
    interrupted: "Interrupted",
    awaiting_answers: "awaiting answers"
  }

  @doc "Human label for a lifecycle status. Prose, not a contract value."
  @spec label(atom()) :: String.t()
  def label(status), do: Map.get(@labels, status, to_string(status))

  @doc """
  Canonical contract status name for a lifecycle status, as emitted into
  markup via `data-status`. `:never_started` folds to `"blocked"` — the
  contract status whose meaning it shares (docs/design-constitution.md §II).
  `:awaiting_answers` (029) gets its own eighth color rather than folding.
  Total: an unrecognised atom folds to `"pending"` rather than raising,
  because a console is an observability surface and MUST NOT crash a view
  over an unexpected status.
  """
  @spec status_class(atom()) :: String.t()
  def status_class(:never_started), do: "blocked"
  def status_class(:interrupted), do: "blocked"

  def status_class(status)
      when status in ~w(done running escalated halted failed pending blocked awaiting_answers)a,
      do: to_string(status)

  def status_class(_other), do: "pending"

  @doc "The eight contract statuses, in the contract's table order."
  @spec statuses() :: [String.t()]
  def statuses,
    do: ~w(done running escalated halted failed pending blocked awaiting_answers)

  attr(:status, :atom, required: true, doc: "one of Feature.status/0")

  def status_pill(assigns) do
    assigns = assign(assigns, class: status_class(assigns.status), label: label(assigns.status))

    ~H"""
    <span class="status-chip" data-status={@class}>
      {@label}
    </span>
    """
  end

  @doc """
  The "round n/m · waited Xm · Ym left" meta line for an awaiting feature
  (029, contracts/operator-surfaces.md "Every status surface") — shared by
  Mission Control, Runs, Run Detail and the feature drawer so waited/left
  read identically everywhere. `nil` when the feature isn't awaiting anything
  (or `pending_questions/0` has no open round for it), rendering nothing.
  """
  @spec awaiting_meta(map() | nil) :: String.t() | nil
  def awaiting_meta(nil), do: nil

  def awaiting_meta(%{round: round, max_rounds: max_rounds} = pending) do
    "round #{round}/#{max_rounds} · waited #{duration_label(elapsed_seconds(pending))} · " <>
      "#{duration_label(remaining_seconds(pending))} left"
  end

  defp elapsed_seconds(%{started_at: started_at}),
    do: DateTime.diff(DateTime.utc_now(), started_at)

  defp remaining_seconds(%{deadline_at: deadline_at}),
    do: max(DateTime.diff(deadline_at, DateTime.utc_now()), 0)

  defp duration_label(seconds) when seconds < 60, do: "#{seconds}s"
  defp duration_label(seconds), do: "#{div(seconds, 60)}m"

  @doc """
  A persisted artifact (a PR, a checkpoint pointer, a transcript path) shown
  as an accent eyebrow naming the artifact over mono key/value pairs (FR-010a)
  — never a bespoke, status-colored box.
  """
  attr(:label, :string, required: true, doc: "the artifact this block names")
  attr(:fields, :list, default: [], doc: "[{key, value}] mono pairs")
  slot(:inner_block, doc: "extra content below the fields, e.g. a link")

  def record_block(assigns) do
    ~H"""
    <div class="record-block">
      <div class="record-block-label">{@label}</div>
      <dl :if={@fields != []} class="record-block-fields">
        <%= for {k, v} <- @fields do %>
          <dt>{k}</dt>
          <dd>{v}</dd>
        <% end %>
      </dl>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A form's start/validation refusal, re-expressed per research.md §4b: an
  inset well, an accent eyebrow naming the refusal, and the message in mono
  `--text-secondary` — never the status palette's `failed` red on a
  non-status element (FR-012).
  """
  attr(:label, :string, required: true, doc: "names the refusal, e.g. \"Start refused\"")
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def form_refusal(assigns) do
    ~H"""
    <div class="form-refusal" {@rest}>
      <div class="form-refusal-label">{@label}</div>
      <p class="form-refusal-message">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  @doc """
  Seven-cell strip in the fixed `Pipeline.phases/0` order. `phases` maps
  `phase => %{state: :pending | :active | :completed, ...}`; missing entries
  render as `:pending`. `status` further distinguishes the active cell when
  the feature has diverted (running vs escalated vs halted vs failed —
  FR-008). `chunk` (015, `ConsoleReadModel.chunk_cell()` | `nil`) adds an
  optional task-phase sub-label to the implement cell only — absent/`nil`/
  `scope: :whole_list` render this **exactly as before 015** (FR-019,
  SC-005; contracts/telemetry-chunk.md §4). `remediation` (017,
  `ConsoleReadModel.remediation_cell()` | `nil`) uses the same sub-label slot
  under the **analyze** cell to show `attempt k/n` while the auto-remediation
  loop is running — absent/`nil` renders the cell exactly as before 017
  (contracts/telemetry-console.md §3).
  """
  attr(:phases, :map, required: true)
  attr(:status, :atom, default: :pending)
  attr(:chunk, :map, default: nil)
  attr(:remediation, :map, default: nil)

  def phase_strip(assigns) do
    assigns =
      assigns
      |> assign(:ordered, Pipeline.phases())
      |> assign(:sublabels, %{
        implement: chunk_sublabel(assigns[:chunk]),
        analyze: remediation_sublabel(assigns[:remediation])
      })

    ~H"""
    <div class="phase-strip">
      <span
        :for={phase <- @ordered}
        class={"phase-cell phase-cell-#{phase_cell_state(Map.get(@phases, phase), @status)}"}
        data-phase={phase}
        title={"#{phase} — #{phase_cell_state(Map.get(@phases, phase), @status)}"}
      >
        {phase}<span :if={@sublabels[phase]} class="phase-sublabel"> {@sublabels[phase]}</span>
      </span>
    </div>
    """
  end

  @doc """
  Current phase of a feature as `{phase, n, total}` (data-model §5): the
  `:active` cell, else the last `:completed` one, else the first phase with
  `n = 1`. Total: unknown or missing cells count as pending.
  """
  @spec phase_position(map() | nil) :: {atom(), pos_integer(), pos_integer()}
  def phase_position(phases) do
    phases = phases || %{}
    ordered = Pipeline.phases()
    indexed = Enum.with_index(ordered, 1)
    state_of = fn phase -> phases |> Map.get(phase) |> then(&(&1 && Map.get(&1, :state))) end

    found =
      Enum.find(indexed, fn {phase, _n} -> state_of.(phase) == :active end) ||
        indexed
        |> Enum.filter(fn {phase, _n} -> state_of.(phase) == :completed end)
        |> List.last() ||
        List.first(indexed)

    {phase, n} = found
    {phase, n, length(ordered)}
  end

  attr(:phases, :map, required: true)

  def phase_position_label(assigns) do
    {phase, n, total} = phase_position(assigns.phases)
    assigns = assign(assigns, phase: phase, n: n, total: total)

    ~H"""
    <span class="phase-position" data-phase-position>{@phase} · {@n}/{@total}</span>
    """
  end

  defp remediation_sublabel(%{attempt: attempt, limit: limit})
       when is_integer(attempt) and is_integer(limit),
       do: "attempt #{attempt}/#{limit}"

  defp remediation_sublabel(_remediation), do: nil

  defp chunk_sublabel(nil), do: nil
  defp chunk_sublabel(%{scope: :whole_list}), do: nil

  defp chunk_sublabel(%{scope: :task_phase} = chunk),
    do: attempt_suffix("#{chunk.ordinal}/#{chunk.total} · #{chunk.title}", chunk[:attempt])

  defp chunk_sublabel(%{scope: :sweep} = chunk),
    do: attempt_suffix("sweep · #{chunk[:remaining]} left", chunk[:attempt])

  defp attempt_suffix(base, attempt) when is_integer(attempt) and attempt > 1,
    do: base <> " (attempt #{attempt})"

  defp attempt_suffix(base, _attempt), do: base

  defp phase_cell_state(nil, _status), do: "pending"
  defp phase_cell_state(%{state: :completed}, _status), do: "completed"
  defp phase_cell_state(%{state: :interrupted}, _status), do: "interrupted"

  defp phase_cell_state(%{state: :active}, status)
       when status in [:escalated, :halted, :failed, :awaiting_answers],
       do: to_string(status)

  defp phase_cell_state(%{state: :active}, _status), do: "active"
  defp phase_cell_state(_cell, _status), do: "pending"

  defp money(amount), do: :erlang.float_to_binary(amount * 1.0, decimals: 2)

  @doc "Render an amount (or `nil`) as a fixed `$0.00`-style string, used by the backlog table, drawer, and run report."
  @spec format_money(number() | nil) :: String.t()
  def format_money(nil), do: money(0.0)
  def format_money(amount) when is_number(amount), do: money(amount)

  @doc """
  Zero-pad a small ordinal (task-phase position, attempt number, phase index)
  to at least two digits, per docs/design-constitution.md's ordinal rule —
  `1` renders `01`, `12` renders `12` unchanged.
  """
  @spec pad_ordinal(non_neg_integer()) :: String.t()
  def pad_ordinal(n) when is_integer(n) and n >= 0, do: String.pad_leading(to_string(n), 2, "0")

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
