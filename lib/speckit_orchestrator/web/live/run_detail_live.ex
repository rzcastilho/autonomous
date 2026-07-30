defmodule SpeckitOrchestrator.Web.RunDetailLive do
  @moduledoc """
  US3 — Run Detail (`/runs/:run_id`, 018 contracts/console-runs.md): one
  run's full record — settings, amendments, and per feature its phase
  attempts (execution order), escalations, remediation attempts, and
  checkpoint — from one place, without hunting across worktree/transcript
  directories. Calls `SpeckitOrchestrator.run_detail/2` and, only when the
  operator opens a specific attempt, `transcript/1` (FR-036, SC-009) — no
  query logic of its own (FR-030c).

  Actions: export the run (`export_run/3`, written under
  `<autonomous_root>/exports/`) and resolve an open escalation
  (`resolve_escalation/2`, FR-026 — records a resolution, never deletes the
  entry).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{Config, ConsoleProjection}

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Run #{run_id}",
       current_path: "/runs",
       run_id: run_id,
       transcript: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_info({:console, _kind, _payload}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    case SpeckitOrchestrator.run_detail(socket.assigns.run_id) do
      {:ok, detail} -> assign(socket, detail: detail, error: nil)
      {:error, reason} -> assign(socket, detail: nil, error: reason)
    end
  end

  @impl true
  def handle_event("open_transcript", %{"ref" => ref}, socket) do
    attempt_id = decode_attempt_ref(socket.assigns.run_id, ref)

    transcript =
      case SpeckitOrchestrator.transcript(attempt_id) do
        {:ok, t} -> Map.from_struct(t)
        {:error, reason} -> %{error: reason}
      end

    {:noreply, assign(socket, transcript: Map.put(transcript, :ref, ref))}
  end

  def handle_event("close_transcript", _params, socket) do
    {:noreply, assign(socket, transcript: nil)}
  end

  def handle_event("resolve_escalation", %{"ref" => ref} = params, socket) do
    escalation_id = decode_escalation_ref(socket.assigns.run_id, ref)
    note = blank_to_nil(Map.get(params, "note"))

    case SpeckitOrchestrator.resolve_escalation(escalation_id, note: note) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Escalation resolved") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Resolve failed: #{inspect(reason)}")}
    end
  end

  def handle_event("export", _params, socket) do
    dir = Path.join(Config.autonomous_root(), "exports")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{socket.assigns.run_id}-#{System.system_time(:second)}.json")

    case SpeckitOrchestrator.export_run(socket.assigns.run_id, path) do
      {:ok, path} ->
        {:noreply, put_flash(socket, :info, "Exported to #{path}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Export failed: #{inspect(reason)}")}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  # ---- attempt / escalation ref encoding -----------------------------------
  #
  # `attempt_id`/escalation `id` are repo-scoped tuples; the page already
  # knows `repo_id`/`run_id` (they're this page's own scope), so the wire
  # format carries only the parts a click can't already supply.

  defp attempt_ref(attempt),
    do: "#{attempt.feature_key |> elem(2)}::#{attempt.phase}::#{attempt.ordinal}"

  defp decode_attempt_ref(run_id, ref) do
    [feature_id, phase, ordinal] = String.split(ref, "::", parts: 3)
    {repo_id(), run_id, feature_id, safe_atom(phase), String.to_integer(ordinal)}
  end

  defp escalation_ref(escalation), do: "#{escalation.feature_id}::#{escalation.id |> elem(3)}"

  defp decode_escalation_ref(run_id, ref) do
    [feature_id, ordinal] = String.split(ref, "::", parts: 2)
    {repo_id(), run_id, feature_id, String.to_integer(ordinal)}
  end

  defp repo_id, do: SpeckitOrchestrator.RepoIdentity.partition(Config.repo())

  defp safe_atom(s), do: String.to_existing_atom(s)

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-run-detail" data-view="run-detail">
      <p :if={@error} class="field-error" data-error={inspect(@error)}>
        Run {@run_id} unavailable ({inspect(@error)}).
      </p>

      <div :if={@detail} data-run-detail={@run_id}>
        <.run_header run={@detail.run} settings={@detail.settings} amendments={@detail.amendments} />

        <div class="run-detail-actions">
          <button type="button" phx-click="export" class="btn-secondary" data-action="export">
            Export run
          </button>
        </div>

        <div :for={f <- @detail.features} class="escalation-card" data-feature={f.feature_id}>
          <div class="escalation-card-head">
            <span class="escalation-title">{f.feature_id} · {f.slug}</span>
            <.status_pill status={f.status} />
            <span :if={f.terminal_reason} class="escalation-reason">
              reason: {inspect(f.terminal_reason)}
            </span>
          </div>

          <div class="escalation-card-body">
            <table class="backlog-table" data-table="phase-attempts">
              <thead>
                <tr>
                  <th>Phase</th>
                  <th>Outcome</th>
                  <th>Model</th>
                  <th>Cost</th>
                  <th>Duration</th>
                  <th>Started</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for a <- f.phase_attempts do %>
                  <tr data-attempt={attempt_ref(a)}>
                    <td>{a.phase} #{pad_ordinal(a.ordinal)}</td>
                    <td>{a.outcome}</td>
                    <td>{a.model}</td>
                    <td>${format_money(a.cost_usd)}</td>
                    <td>{format_elapsed(a.duration_ms)}</td>
                    <td>{format_datetime(a.started_at)}</td>
                    <td>
                      <button
                        type="button"
                        phx-click="open_transcript"
                        phx-value-ref={attempt_ref(a)}
                        class="btn-secondary"
                        data-action={"transcript-#{attempt_ref(a)}"}
                      >
                        Transcript
                      </button>
                    </td>
                  </tr>
                  <tr
                    :if={@transcript && @transcript.ref == attempt_ref(a)}
                    class="transcript-row"
                    data-transcript-row={attempt_ref(a)}
                  >
                    <td colspan="7">
                      <div class="transcript-panel" data-transcript={@transcript.ref}>
                        <div class="checkpoint-box-label">
                          TRANSCRIPT
                          <button type="button" phx-click="close_transcript" class="btn-secondary">
                            &times;
                          </button>
                        </div>
                        <p :if={@transcript[:error]} class="field-error">
                          {inspect(@transcript.error)}
                        </p>
                        <pre :if={@transcript[:body]} class="transcript-body">{@transcript.body}</pre>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>

            <div :if={f.checkpoint} class="checkpoint-box" data-checkpoint="ok">
              <div class="checkpoint-box-label"><span class="checkpoint-dot"></span> CHECKPOINT</div>
              <dl class="checkpoint-fields">
                <dt>phase</dt>
                <dd>{f.checkpoint.phase}</dd>
                <dt>status</dt>
                <dd>{f.checkpoint.status}</dd>
                <dt>reason</dt>
                <dd>{inspect(f.checkpoint.reason)}</dd>
              </dl>
            </div>

            <div :if={f.remediation_attempts != []} data-remediation-attempts>
              <div class="run-context-label">REMEDIATION ATTEMPTS</div>
              <div :for={r <- f.remediation_attempts} class="run-context" data-remediation={r.ordinal}>
                <span class="run-context-chip">
                  #{pad_ordinal(r.ordinal)} severity=<span>{r.max_severity}</span>
                  outcome=<span>{r.outcome}</span>
                  limit=<span>{r.attempt_limit}</span>
                  threshold=<span>{r.threshold}</span>
                  cost=<span>${format_money(r.cost_usd)}</span>
                </span>
              </div>
            </div>

            <div :if={f.escalations != []} data-escalations>
              <div class="run-context-label">ESCALATIONS</div>
              <div
                :for={e <- f.escalations}
                class="clarify-block"
                data-escalation={escalation_ref(e)}
              >
                <div>
                  {e.kind} at {e.phase}
                  <span :if={e.severity}>· severity {e.severity}</span>
                  <span :if={e.resolution} class="badge badge-neutral" data-marker="resolved">
                    resolved {format_datetime(e.resolution[:resolved_at])}
                  </span>
                </div>
                <pre>reason: {inspect(e.reason)} / evidence: {inspect(e.evidence)}</pre>
                <form
                  :if={!e.resolution}
                  phx-submit="resolve_escalation"
                  class="resume-form"
                  data-form={"resolve-#{escalation_ref(e)}"}
                >
                  <input type="hidden" name="ref" value={escalation_ref(e)} />
                  <label class="field-label">
                    Note
                    <textarea name="note" phx-debounce="200" class="resume-textarea"></textarea>
                  </label>
                  <button type="submit" class="btn-primary" data-action={"resolve-#{escalation_ref(e)}"}>
                    &check; Resolve
                  </button>
                </form>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:run, :map, required: true)
  attr(:settings, :map, required: true)
  attr(:amendments, :list, required: true)

  defp run_header(assigns) do
    ~H"""
    <div class="escalations-intro" data-run-header>
      <div class="escalations-title">
        Run {@run.run_id}
        <span :if={not @run.record_complete?} class="badge badge-warn" data-marker="incomplete">
          incomplete
        </span>
      </div>
      <div class="escalations-sub">
        {@run.state} · {@run.outcome || "—"} · started {format_datetime(@run.started_at)}
        · {format_elapsed(@run.duration_ms)} · ${format_money(@run.spend_usd)}
        <span :if={@run.halt_reason}>· halted: {inspect(@run.halt_reason)}</span>
        <span :if={@run.stopped_by} data-marker="stopped-by">
          · stopped at {@run.stopped_by} ({inspect(@run.stopped_reason)})
        </span>
      </div>

      <div class="run-context-label">SETTINGS</div>
      <div class="run-context">
        <span :for={{k, v} <- @settings} class="run-context-chip">
          {k}=<span>{inspect(v)}</span>
        </span>
      </div>

      <div :if={@amendments != []} data-amendments>
        <div class="run-context-label">AMENDMENTS</div>
        <div :for={a <- @amendments} class="run-context" data-amendment={a.ordinal}>
          <span class="run-context-chip">
            #{pad_ordinal(a.ordinal)} {format_datetime(a.effective_at)} after=<span>{inspect(a.effective_after)}</span>
            changes=<span>{inspect(a.changes)}</span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
