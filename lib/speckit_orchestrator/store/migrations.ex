defmodule SpeckitOrchestrator.Store.Migrations do
  @moduledoc """
  Ordered `{version, description, fun}` list applied at boot inside
  transactions, using `:mnesia.transform_table/3` for attribute changes (018,
  research R13, contracts/schema.md § Schema versioning). Version 1 was the
  schema this feature ships with. Version 2 (feature 019,
  contracts/store-schema-v2.md) is a clean break: no v1 record is readable, so
  its migration **refuses** rather than transforms — a v1 directory aborts
  startup naming the incompatibility (FR-022, FR-023) instead of being
  silently migrated or destroyed.

  Version 3 appends `feature_run.pr_url` — the URL `gh pr create` returned for
  a `:done` feature, which used to be logged and then dropped, leaving the
  console's "View PR" affordance with nothing to link to. A v2 record is
  readable as-is, so this one really does transform: every existing row gets
  `nil` (its PR, if any, was opened before the URL was ever recorded).

  Version 4 (feature 021, contracts/advanced-record.md §2.2) appends
  `feature_run.advanced_with_findings` — the record of a feature that advanced
  under the `:proceed` exhaustion policy past a residual finding the gate
  would otherwise have escalated. Structurally identical to version 3: a plain
  append, every v3 row gets `nil` (the fact did not exist when those rows were
  written).
  """

  alias SpeckitOrchestrator.Store.{Mnesia, Schema}

  @type migration :: {pos_integer(), String.t(), (-> :ok | {:error, term()})}

  # The exact attribute shape each historical migration transforms INTO — not
  # `Schema.table/1`, which always reflects the CURRENT (latest) schema and
  # would hand a later version's attribute count to an earlier version's
  # transform.
  @feature_run_v3_attributes [
    :key,
    :run_key,
    :feature_id,
    :slug,
    :path,
    :number,
    :group,
    :created_at,
    :status,
    :terminal_reason,
    :worktree_path,
    :branch,
    :pr_description,
    :started_at,
    :ended_at,
    :pr_url
  ]

  @doc "The schema version this build of the orchestrator understands."
  @spec current_version() :: pos_integer()
  def current_version, do: 4

  @doc "Every migration, ascending by version."
  @spec all() :: [migration()]
  def all do
    [
      {2, "019 clean break — pre-019 records are not readable",
       fn -> {:error, {:incompatible_record, 1}} end},
      {3, "append feature_run.pr_url", &add_pr_url/0},
      {4, "append feature_run.advanced_with_findings", &add_advanced_with_findings/0}
    ]
  end

  # `:pr_url` is the last attribute in the v3 table shape, so the transform is
  # a plain append — no field of an existing row moves position.
  defp add_pr_url do
    transform_table(
      :speckit_feature_run,
      &Tuple.insert_at(&1, tuple_size(&1), nil),
      @feature_run_v3_attributes
    )
  end

  # `:advanced_with_findings` is the last attribute in the current table
  # shape, so this is likewise a plain append.
  defp add_advanced_with_findings do
    transform_table(
      :speckit_feature_run,
      &Tuple.insert_at(&1, tuple_size(&1), nil),
      Schema.table(:speckit_feature_run).attributes
    )
  end

  @doc """
  Apply every migration whose version is greater than `from_version`
  (`nil` means "apply everything", i.e. a fresh schema with no prior
  version recorded), in ascending order. `:ok` once every pending migration
  has run; `{:error, reason}` on the first failure, leaving later migrations
  unapplied.
  """
  @spec apply_pending(pos_integer() | nil) :: :ok | {:error, term()}
  def apply_pending(from_version) do
    floor = from_version || 0

    all()
    |> Enum.filter(fn {version, _description, _fun} -> version > floor end)
    |> Enum.sort_by(fn {version, _description, _fun} -> version end)
    |> Enum.reduce_while(:ok, fn {_version, _description, fun}, :ok ->
      case fun.() do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Helper a migration's `fun` calls to change a table's attribute shape."
  @spec transform_table(atom(), (tuple() -> tuple()), [atom()]) :: :ok | {:error, term()}
  def transform_table(table, fun, new_attributes),
    do: Mnesia.transform_table(table, fun, new_attributes)
end
