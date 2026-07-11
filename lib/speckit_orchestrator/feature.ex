defmodule SpeckitOrchestrator.Feature do
  @moduledoc """
  A single unit of work parsed from a `docs/breakdown/NNN-*.md` file.

  * `id` — zero-padded numeric string, e.g. `"001"` (the `NNN` prefix).
  * `slug` — kebab-case name from the filename, e.g. `"core-ledger"`.
  * `path` — absolute or repo-relative path to the source breakdown file.
  * `prereqs` — list of feature `id`s that must reach `:done` before this
    feature may be released.
  * `status` — lifecycle state (see `t:status/0`). Fresh features load as
    `:pending`.
  """

  @enforce_keys [:id, :slug, :path]
  defstruct id: nil, slug: nil, path: nil, prereqs: [], status: :pending

  @type status ::
          :pending
          | :running
          | :done
          | :escalated
          | :halted
          | :failed
          | :blocked

  @type t :: %__MODULE__{
          id: String.t(),
          slug: String.t(),
          path: String.t(),
          prereqs: [String.t()],
          status: status()
        }

  @terminal_statuses [:done, :escalated, :halted, :failed]

  @doc "Statuses from which a feature never advances further."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "True when the feature has reached a terminal lifecycle state."
  @spec terminal?(t() | status()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status) when is_atom(status), do: status in @terminal_statuses
end
