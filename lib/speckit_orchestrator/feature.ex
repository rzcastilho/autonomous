defmodule SpeckitOrchestrator.Feature do
  @moduledoc """
  A single unit of work parsed from a `docs/breakdown/NNN-*.md` file, or built
  ad hoc via `SingleSpec`.

  * `id` — zero-padded numeric string, e.g. `"001"` (the `NNN` prefix).
  * `number` — the same value as an integer, the sole ordering key (FR-009,
    FR-010). Compared numerically, so `"002"` and `"0002"` are the same number.
  * `slug` — kebab-case name from the filename, e.g. `"core-ledger"`.
  * `path` — absolute or repo-relative path to the source breakdown file.
  * `group` — `:backlog` (ordered by `number`) or `:ad_hoc` (ordered by
    `created_at`, never joins the chain — FR-024, FR-028).
  * `created_at` — set only for `:ad_hoc` features; `nil` for `:backlog`.
  * `status` — lifecycle state (see `t:status/0`). Fresh features load as
    `:pending`.
  * `spec_number` — repo-monotonic spec number, distinct from `id`/`number`.
    `nil` until allocated. Governs the spec directory, the branch name, and
    artifact resolution — nothing else (see `spec_id/1`, `spec_label/1`).
  """

  @enforce_keys [:id, :number, :slug, :path]
  defstruct id: nil,
            number: nil,
            slug: nil,
            path: nil,
            group: :backlog,
            created_at: nil,
            status: :pending,
            spec_number: nil

  @type status ::
          :pending
          | :running
          | :done
          | :escalated
          | :halted
          | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          number: pos_integer(),
          slug: String.t(),
          path: String.t(),
          group: :backlog | :ad_hoc,
          created_at: DateTime.t() | nil,
          status: status(),
          spec_number: pos_integer() | nil
        }

  @terminal_statuses [:done, :escalated, :halted, :failed]

  @doc "Statuses from which a feature never advances further."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "True when the feature has reached a terminal lifecycle state."
  @spec terminal?(t() | status()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status) when is_atom(status), do: status in @terminal_statuses

  @doc """
  Zero-padded spec number for path and branch composition. Falls back to `id`
  when `spec_number` is `nil` (dry runs, the pure unit suite, and wave 1 where
  the two coincide anyway) — see plan.md Complexity Tracking.
  """
  @spec spec_id(t()) :: String.t()
  def spec_id(%__MODULE__{spec_number: nil, id: id}), do: id
  def spec_id(%__MODULE__{spec_number: n}), do: pad(n)

  @doc """
  Zero-padded spec number for operator surfaces. `nil` when unallocated, so a
  surface reports "not allocated" instead of borrowing the wave number.
  """
  @spec spec_label(t()) :: String.t() | nil
  def spec_label(%__MODULE__{spec_number: nil}), do: nil
  def spec_label(%__MODULE__{spec_number: n}), do: pad(n)

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 3, "0")
end
