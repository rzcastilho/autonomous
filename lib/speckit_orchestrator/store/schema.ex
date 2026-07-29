defmodule SpeckitOrchestrator.Store.Schema do
  @moduledoc """
  The twelve table specs as data (018, contracts/schema.md § Tables). Pure —
  no `:mnesia` reference (Principle I). `Store.Boot` creates tables from this,
  `Store.Records` shapes tuples from this, `Store.Migrations` evolves it, and
  `Store.Mnesia` is the only module that turns any of this into a real
  `:mnesia.create_table/2` call.

  Attribute lists are ordered; attribute 1 (the second tuple element, after
  the table name) is always the primary key.
  """

  @type storage_type :: :disc_copies | :disc_only_copies
  @type table_kind :: :set | :ordered_set
  @type table_spec :: %{
          name: atom(),
          attributes: [atom(), ...],
          type: table_kind(),
          storage: storage_type(),
          index: [atom()]
        }

  @doc "Every table spec, in the order `contracts/schema.md` lists them."
  @spec tables() :: [table_spec(), ...]
  def tables do
    [
      %{
        name: :speckit_meta,
        attributes: [:key, :value],
        type: :set,
        storage: :disc_copies,
        index: []
      },
      %{
        name: :speckit_seq,
        attributes: [:repo_id, :next_seq, :origin, :local_path],
        type: :set,
        storage: :disc_copies,
        index: []
      },
      %{
        name: :speckit_run,
        attributes: [
          :key,
          :repo_id,
          :run_id,
          :state,
          :outcome,
          :outcome_index,
          :started_at,
          :ended_at,
          :duration_ms,
          :spend_usd,
          :record_complete?,
          :halt_reason,
          :stopped_by,
          :stopped_reason,
          :scope,
          :layout,
          :superseded_by,
          :schema_version
        ],
        type: :ordered_set,
        storage: :disc_copies,
        index: [:repo_id, :outcome_index]
      },
      %{
        name: :speckit_run_settings,
        attributes: [:run_key, :settings, :captured_at],
        type: :set,
        storage: :disc_copies,
        index: []
      },
      %{
        name: :speckit_settings_amendment,
        attributes: [:id, :run_key, :ordinal, :changes, :effective_at, :effective_after],
        type: :set,
        storage: :disc_copies,
        index: [:run_key]
      },
      %{
        name: :speckit_feature_run,
        attributes: [
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
          :ended_at
        ],
        type: :set,
        storage: :disc_copies,
        index: [:run_key, :feature_id]
      },
      %{
        name: :speckit_phase_attempt,
        attributes: [
          :attempt_id,
          :run_key,
          :feature_key,
          :phase,
          :ordinal,
          :step,
          :label,
          :started_at,
          :ended_at,
          :duration_ms,
          :outcome,
          :model,
          :cost_usd,
          :cost_kind,
          :substep,
          :session_id,
          :error
        ],
        type: :set,
        storage: :disc_copies,
        index: [:run_key, :feature_key]
      },
      %{
        name: :speckit_checkpoint,
        attributes: [
          :key,
          :run_key,
          :phase,
          :last_completed_phase,
          :status,
          :reason,
          :session_id,
          :implement_chunk,
          :analyze_remediation,
          :updated_at
        ],
        type: :set,
        storage: :disc_copies,
        index: [:run_key]
      },
      %{
        name: :speckit_escalation,
        attributes: [
          :id,
          :run_key,
          :feature_id,
          :kind,
          :phase,
          :severity,
          :reason,
          :evidence,
          :raised_at,
          :resolution
        ],
        type: :set,
        storage: :disc_copies,
        index: [:run_key, :feature_id]
      },
      %{
        name: :speckit_remediation_attempt,
        attributes: [
          :id,
          :run_key,
          :feature_key,
          :ordinal,
          :findings,
          :max_severity,
          :outcome,
          :cost_usd,
          :attempt_limit,
          :threshold,
          :model,
          :attempt_id
        ],
        type: :set,
        storage: :disc_copies,
        index: [:run_key, :feature_key]
      },
      %{
        name: :speckit_cost_entry,
        attributes: [:id, :run_key, :amount_usd, :kind, :recorded_at],
        type: :set,
        storage: :disc_copies,
        index: [:run_key]
      },
      %{
        name: :speckit_transcript,
        attributes: [:attempt_id, :body, :bytes, :written_at],
        type: :set,
        storage: :disc_only_copies,
        index: []
      }
    ]
  end

  @doc "The spec for one table, or `nil` if `name` is not a store table."
  @spec table(atom()) :: table_spec() | nil
  def table(name) when is_atom(name), do: Enum.find(tables(), &(&1.name == name))

  @doc "Every table name, in `tables/0` order."
  @spec names() :: [atom(), ...]
  def names, do: Enum.map(tables(), & &1.name)
end
