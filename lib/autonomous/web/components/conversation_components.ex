defmodule Autonomous.Web.ConversationComponents do
  @moduledoc """
  Function components for the agent conversation views (features 040, 042):
  one `conversation_row/1` per `Web.ConversationRows` block, used by the live
  view and the saved-conversation pane so both read identically, and the
  sticky `status_line/1` fed by `Web.SessionStatus`.

  Machine values (tool names, JSON, tool output, ids) are mono; the model's own
  prose goes through `TranscriptMarkup` in the sans prose role. Status colour
  appears only on the end marker's outcome chip and the status line's activity
  dot, as a `data-status` name.
  """

  use Phoenix.Component

  alias Autonomous.Web.{SessionStatus, TranscriptMarkup}

  attr(:id, :string, required: true)
  attr(:row, :map, required: true, doc: "a `ConversationRows` block")
  attr(:expand_event, :string, default: "expand")

  def conversation_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="conv-row"
      data-kind={@row.kind}
      data-class={@row.class}
      data-flag={@row.flag}
      data-error={to_string(@row.flag == :is_error)}
      data-unfinished={to_string(@row.unfinished?)}
    >
      <%= case @row.class do %>
        <% :prose -> %>
          <div class="conv-meta"><span class="conv-label">{@row.label}</span></div>
          <div :if={@row.format == :markup} class="conv-prose transcript-body">
            {TranscriptMarkup.render(@row.body)}
          </div>
          <.omitted row={@row} expand_event={@expand_event} />
        <% :context -> %>
          <details class="conv-fold conv-context">
            <summary>
              <span class="conv-label">{@row.label}</span>
              <span class="conv-first">{@row.summary}</span>
            </summary>
            <pre class="conv-text" data-format={@row.format}>{@row.body}</pre>
            <.omitted row={@row} expand_event={@expand_event} />
          </details>
        <% :thinking -> %>
          <details :if={@row.body != ""} class="conv-fold conv-thinking">
            <summary>
              <span class="conv-label">thinking</span>
              <span class="conv-first">{@row.summary}</span>
            </summary>
            <pre class="conv-text" data-format="plain">{@row.body}</pre>
            <.omitted row={@row} expand_event={@expand_event} />
          </details>
          <div :if={@row.body == ""} class="conv-meta">
            <span class="conv-label">thinking</span>
          </div>
        <% :call -> %>
          <details class="conv-fold conv-call">
            <summary class="conv-call-line" data-format="mono">{@row.summary}</summary>
            <pre class="conv-text" data-format="mono">{@row.body}</pre>
            <.omitted row={@row} expand_event={@expand_event} />
          </details>
          <span :if={@row.unfinished?} class="conv-flag">unfinished</span>
          <.result_part row={@row} expand_event={@expand_event} />
        <% :result -> %>
          <div class="conv-meta">
            <span class="conv-label">tool result</span>
            <span :if={@row.tool_name} class="conv-tool">{@row.tool_name}</span>
          </div>
          <.result_part row={@row} expand_event={@expand_event} />
        <% :stderr -> %>
          <div class="conv-meta">
            <span class="conv-label">{@row.label}</span>
            <span :if={@row.repeat > 1} class="conv-flag" data-repeat>×{@row.repeat}</span>
          </div>
          <pre class="conv-text conv-stderr" data-format="mono">{@row.body}</pre>
        <% :marker -> %>
          <details class="conv-fold conv-marker">
            <summary>
              <span class="conv-first" data-format="mono">{@row.summary}</span>
              <span :if={@row.flag == :hook_failed} class="conv-flag">hook failed</span>
              <span :if={@row.flag == :result_error} class="conv-flag">result error</span>
            </summary>
            <pre class="conv-text" data-format="mono">{@row.body}</pre>
          </details>
        <% :divider -> %>
          <div class="conv-divider" data-format="mono">{@row.summary}</div>
        <% :end -> %>
          <div class="conv-end">
            <span class="conv-label">end</span>
            <span class="status-chip" data-status={@row.chip}>{@row.outcome}</span>
          </div>
        <% _ -> %>
          <details class="conv-fold conv-raw">
            <summary>
              <span class="conv-first" data-format="mono">{@row.summary}</span>
            </summary>
            <pre class="conv-text" data-format="mono">{@row.body}</pre>
            <.omitted row={@row} expand_event={@expand_event} />
          </details>
      <% end %>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:expand_event, :string, required: true)

  defp result_part(assigns) do
    ~H"""
    <div :if={@row.result} class="conv-result" data-result>
      <span :if={@row.result.error?} class="conv-flag">is_error: true</span>
      <pre class="conv-text" data-format="mono">{@row.result.full || @row.result.preview}</pre>
      <p :if={@row.result.more_lines > 0 and is_nil(@row.result.full)} class="conv-omitted">
        <button
          type="button"
          class="conv-expand"
          phx-click={@expand_event}
          phx-value-seq={@row.result.seq}
          data-expand={@row.result.seq}
        >
          +{@row.result.more_lines} lines
        </button>
      </p>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:expand_event, :string, required: true)

  defp omitted(assigns) do
    ~H"""
    <p :if={@row.omitted} class="conv-omitted">
      … {@row.omitted.lines} lines / {@row.omitted.chars} chars omitted
      <button
        type="button"
        class="conv-expand"
        phx-click={@expand_event}
        phx-value-seq={@row.seq}
        data-expand={@row.seq}
      >
        expand
      </button>
    </p>
    """
  end

  attr(:all_frames?, :boolean, required: true)

  @doc "The `show all frames` switch (feature 042): every recorded entry as a folded row."
  def frames_toggle(assigns) do
    ~H"""
    <label class="pr-toggle conv-frames">
      <input
        type="checkbox"
        class="switch-input"
        checked={@all_frames?}
        phx-click="toggle_frames"
        data-frames={if @all_frames?, do: "all", else: "default"}
        aria-label="show all frames"
      />
      <span class="switch-track"><span class="switch-knob"></span></span>
      <span class="option-name">show all frames</span>
    </label>
    """
  end

  attr(:status, :map, required: true, doc: "a `SessionStatus`")

  @doc "Model alias · resolved model · CLI version, each only when known."
  def model_header(assigns) do
    ~H"""
    <span :if={@status.model_alias} class="conv-header-model" data-header-model>{@status.model_alias}</span>
    <span :if={@status.model_resolved} class="conv-header-model" data-header-resolved>{@status.model_resolved}</span>
    <span :if={@status.cli_version} class="conv-header-model" data-header-cli>cli {@status.cli_version}</span>
    """
  end

  attr(:status, :map, required: true, doc: "a `SessionStatus`")
  attr(:live?, :boolean, default: false)
  attr(:now, :any, default: nil, doc: "DateTime the elapsed clock reads against (live only)")

  @doc """
  The sticky bottom status line: activity, counters, background work, elapsed,
  tokens, rate limit, cost and duration — each group only when it has something true to
  say. Pulse and tick exist only while `live?`.
  """
  def status_line(assigns) do
    status = assigns.status
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns,
        activity: SessionStatus.activity_text(status),
        dot: SessionStatus.status_name(status, assigns.live?),
        elapsed: if(assigns.live? or status.ended_at, do: SessionStatus.elapsed_s(status, now)),
        lb?: status.lower_bound?,
        tokens: SessionStatus.tokens_text(status)
      )

    ~H"""
    <section class="conv-status" role="region" aria-label="session status" data-conv-status>
      <span class="conv-status-group" data-activity>
        <span class="transcript-live" data-live={to_string(@live? and is_nil(@status.outcome))} data-status={@dot}></span>
        {@activity}
      </span>
      <span class="conv-status-group" data-turns>
        turns {SessionStatus.count_text(@status.turns, @lb?)}
      </span>
      <span class="conv-status-group" data-tools>
        tools {SessionStatus.count_text(@status.tool_calls, @lb?)}
      </span>
      <span :if={@tokens} class="conv-status-group" data-tokens>{@tokens}</span>
      <span :if={@status.open_tasks > 0} class="conv-status-group" data-tasks>
        bg {@status.open_tasks}
      </span>
      <span :if={@elapsed} class="conv-status-group" data-elapsed>{format_elapsed(@elapsed)}</span>
      <span :if={@status.rate_limit} class="conv-status-group" data-rate-limit>
        rate limit · {@status.rate_limit.type}{resets(@status.rate_limit.resets_at)}
      </span>
      <span :if={@status.cost_usd} class="conv-status-group" data-cost>
        {format_cost(@status.cost_usd)}
      </span>
      <span :if={@status.duration_ms} class="conv-status-group" data-duration>
        {format_elapsed(div(@status.duration_ms, 1000))}
      </span>
      <p class="sr-only" aria-live="polite" data-announce>{@status.announce}</p>
    </section>
    """
  end

  defp format_elapsed(s) when s >= 3600,
    do: "#{div(s, 3600)}h #{pad(div(rem(s, 3600), 60))}m #{pad(rem(s, 60))}s"

  defp format_elapsed(s) when s >= 60, do: "#{div(s, 60)}m #{pad(rem(s, 60))}s"
  defp format_elapsed(s), do: "#{s}s"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp format_cost(cost), do: "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 2)

  defp resets(nil), do: ""

  defp resets(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> " · resets " <> Calendar.strftime(dt, "%H:%M")
      _ -> ""
    end
  end

  defp resets(_), do: ""
end
