defmodule Autonomous.BackgroundMarker do
  @moduledoc """
  CLI-contract boundary (feature 032): the only module that knows how the
  Claude Code CLI words "this Bash command was moved to the background".

  Pinned to `claude` **2.1.287** and recorded in `docs/harness-contract.md`.
  A CLI bump that rewords a marker is fixed here and nowhere else; the pure
  detector in `PhaseResult` only sees the parsed shape.

  Four marker modes exist:

    * `:timeout` — the command hit its Bash timeout and the CLI auto-backgrounded it
    * `:message` — the CLI moved it to the background for another reason
    * `:manual`  — backgrounded by the user
    * `:explicit` — the model passed `run_in_background: true`

  Patterns are case-sensitive and checked in this order (most specific first).
  """

  @type mode :: :timeout | :message | :manual | :explicit
  @type parsed :: %{mode: mode(), task_id: String.t() | nil, output_path: String.t() | nil}

  @modes [
    timeout:
      ~r/Command did not complete within its \d+s timeout and was moved to the background \(ID: (?<id>[^)\s]+)\)/,
    message: ~r/Command was moved to the background \(ID: (?<id>[^)\s]+)\)/,
    manual: ~r/Command was manually backgrounded by user with ID: (?<id>\S+?)\.?(?:\s|$)/,
    explicit: ~r/Command running in background with ID: (?<id>\S+?)\.?(?:\s|$)/
  ]

  @path ~r/Output is being written to: (?<path>\S+?)\.?(?:\s|$)/

  @doc """
  Parse a tool result's `output` (a string, or a list of content blocks).
  `{:ok, parsed}` when a backgrounding marker is present, `:none` otherwise
  (including non-text output).
  """
  @spec parse(term()) :: {:ok, parsed()} | :none
  def parse(output) do
    with text when is_binary(text) <- flatten(output),
         {mode, %{"id" => id}} <- match_mode(text) do
      {:ok, %{mode: mode, task_id: id, output_path: output_path(text)}}
    else
      _ -> :none
    end
  end

  @doc "True when a tool call's input asked for `run_in_background: true`."
  @spec explicit_call?(term()) :: boolean()
  def explicit_call?(%{"run_in_background" => true}), do: true
  def explicit_call?(_input), do: false

  @doc """
  Flatten a tool result `output` to text: a binary stays, a list of content
  blocks (`%{"type" => "text", "text" => t}` or bare binaries) is joined, and
  anything else is `nil`.
  """
  @spec flatten(term()) :: String.t() | nil
  def flatten(text) when is_binary(text), do: text

  def flatten(blocks) when is_list(blocks) do
    texts =
      Enum.flat_map(blocks, fn
        %{"text" => t} when is_binary(t) -> [t]
        t when is_binary(t) -> [t]
        _ -> []
      end)

    if texts == [], do: nil, else: Enum.join(texts, "\n")
  end

  def flatten(_other), do: nil

  defp match_mode(text) do
    Enum.find_value(@modes, fn {mode, re} ->
      case Regex.named_captures(re, text) do
        nil -> nil
        caps -> {mode, caps}
      end
    end)
  end

  defp output_path(text) do
    case Regex.named_captures(@path, text) do
      %{"path" => path} -> path
      nil -> nil
    end
  end
end
