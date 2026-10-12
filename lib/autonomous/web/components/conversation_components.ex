defmodule Autonomous.Web.ConversationComponents do
  @moduledoc """
  Function components for the agent conversation views (feature 040): one
  `conversation_row/1` per `Web.ConversationRows` row, used by the live view
  and the saved-conversation pane so both read identically.

  Machine values (tool names, JSON, tool output, ids) are mono; the model's own
  prose goes through `TranscriptMarkup` in the sans prose role. Status colour
  appears only on the end marker's outcome chip, as a `data-status` name.
  """

  use Phoenix.Component

  alias Autonomous.Web.TranscriptMarkup

  attr(:id, :string, required: true)
  attr(:row, :map, required: true, doc: "a `ConversationRows` row")
  attr(:expand_event, :string, default: "expand")

  def conversation_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="conv-row"
      data-kind={@row.kind}
      data-error={to_string(@row.error?)}
      data-unfinished={to_string(@row.unfinished?)}
    >
      <div class="conv-meta">
        <span class="conv-label">{@row.label}</span>
        <span :if={@row.tool_name} class="conv-tool">{@row.tool_name}</span>
        <span :if={@row.error?} class="conv-flag">is_error: true</span>
        <span :if={@row.unfinished?} class="conv-flag">unfinished</span>
      </div>

      <%= case @row.kind do %>
        <% :end -> %>
          <div class="conv-end">
            <span class="status-chip" data-status={@row.chip}>{@row.outcome}</span>
          </div>
        <% :thinking -> %>
          <details class="conv-thinking">
            <summary>thinking</summary>
            <div class="conv-text">{@row.text}</div>
          </details>
        <% _ -> %>
          <div :if={@row.format == :markup} class="conv-prose transcript-body">
            {TranscriptMarkup.render(@row.text)}
          </div>
          <pre :if={@row.format != :markup} class="conv-text" data-format={@row.format}>{@row.text}</pre>
      <% end %>

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
    </div>
    """
  end
end
