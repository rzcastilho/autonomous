defmodule SpeckitOrchestrator.Store.Records do
  @moduledoc """
  Pure structs + tuple codecs for the store's twelve tables (018,
  contracts/schema.md § Damaged-state reporting). No `:mnesia` reference
  (Principle I) — `encode/1`/`decode/2` shape `:mnesia` record tuples using
  `Store.Schema`'s attribute lists as the sole source of truth for field order
  and membership, and never invent or default a field: a shape mismatch is
  reported as `{:error, {:damaged, key, reason}}`, never silently coerced
  (FR-008, SC-011).
  """

  alias SpeckitOrchestrator.Store.{Schema, Shape}

  defmodule Meta do
    @moduledoc false
    defstruct [:key, :value]
    @type t :: %__MODULE__{key: atom(), value: term()}
  end

  defmodule Seq do
    @moduledoc false
    defstruct [:repo_id, :next_seq, :origin, :local_path]

    @type t :: %__MODULE__{
            repo_id: binary(),
            next_seq: pos_integer(),
            origin: binary() | nil,
            local_path: binary()
          }
  end

  defmodule Run do
    @moduledoc false
    defstruct [
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
    ]

    @type t :: %__MODULE__{
            key: {binary(), binary()},
            repo_id: binary(),
            run_id: binary(),
            state: :in_flight | :parked | :completed | :superseded,
            outcome:
              :all_done
              | :escalated
              | :halted
              | :failed
              | :mixed
              | :ended_by_operator
              | nil,
            outcome_index: atom(),
            started_at: DateTime.t(),
            ended_at: DateTime.t() | nil,
            duration_ms: integer() | nil,
            spend_usd: float(),
            record_complete?: boolean(),
            halt_reason: term() | nil,
            stopped_by: binary() | nil,
            stopped_reason: term() | nil,
            scope: {:breakdown, binary()} | :ad_hoc,
            layout: map(),
            superseded_by: binary() | nil,
            schema_version: pos_integer()
          }
  end

  defmodule RunSettings do
    @moduledoc false
    defstruct [:run_key, :settings, :captured_at]

    @type t :: %__MODULE__{
            run_key: {binary(), binary()},
            settings: map(),
            captured_at: DateTime.t()
          }
  end

  defmodule SettingsAmendment do
    @moduledoc false
    defstruct [:id, :run_key, :ordinal, :changes, :effective_at, :effective_after]

    @type t :: %__MODULE__{
            id: {binary(), binary(), pos_integer()},
            run_key: {binary(), binary()},
            ordinal: pos_integer(),
            changes: map(),
            effective_at: DateTime.t(),
            effective_after: tuple() | nil
          }
  end

  defmodule FeatureRun do
    @moduledoc false
    defstruct [
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
      :pr_url,
      :started_at,
      :ended_at
    ]

    @type t :: %__MODULE__{
            key: {binary(), binary(), binary()},
            run_key: {binary(), binary()},
            feature_id: binary(),
            slug: binary(),
            path: binary(),
            number: pos_integer(),
            group: :backlog | :ad_hoc,
            created_at: DateTime.t() | nil,
            status:
              :pending
              | :running
              | :done
              | :escalated
              | :halted
              | :failed
              | :never_started
              | :ended_by_supersession,
            terminal_reason: term() | nil,
            worktree_path: binary() | nil,
            branch: binary() | nil,
            pr_description: map() | nil,
            pr_url: binary() | nil,
            started_at: DateTime.t() | nil,
            ended_at: DateTime.t() | nil
          }
  end

  defmodule PhaseAttempt do
    @moduledoc false
    defstruct [
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
    ]

    @type t :: %__MODULE__{
            attempt_id: {binary(), binary(), binary(), atom(), pos_integer()},
            run_key: {binary(), binary()},
            feature_key: {binary(), binary(), binary()},
            phase: atom(),
            ordinal: pos_integer(),
            step: non_neg_integer(),
            label: binary(),
            started_at: DateTime.t(),
            ended_at: DateTime.t(),
            duration_ms: integer(),
            outcome: atom(),
            model: binary(),
            cost_usd: float(),
            cost_kind: :actual | :estimate,
            substep: map() | nil,
            session_id: binary() | nil,
            error: term() | nil
          }
  end

  defmodule Checkpoint do
    @moduledoc false
    defstruct [
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
    ]

    @type t :: %__MODULE__{
            key: {binary(), binary(), binary()},
            run_key: {binary(), binary()},
            phase: atom(),
            last_completed_phase: atom(),
            status: :in_progress | :escalated | :halted | :failed,
            reason: term() | nil,
            session_id: binary() | nil,
            implement_chunk: map() | nil,
            analyze_remediation: map() | nil,
            updated_at: DateTime.t()
          }
  end

  defmodule Escalation do
    @moduledoc false
    defstruct [
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
    ]

    @type t :: %__MODULE__{
            id: {binary(), binary(), binary(), pos_integer()},
            run_key: {binary(), binary()},
            feature_id: binary(),
            kind: :escalated | :halted,
            phase: atom(),
            severity: :low | :medium | :high | :critical | nil,
            reason: term(),
            evidence: map(),
            raised_at: DateTime.t(),
            resolution: map() | nil
          }
  end

  defmodule RemediationAttempt do
    @moduledoc false
    defstruct [
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
    ]

    @type t :: %__MODULE__{
            id: {binary(), binary(), binary(), pos_integer()},
            run_key: {binary(), binary()},
            feature_key: {binary(), binary(), binary()},
            ordinal: pos_integer(),
            findings: list(),
            max_severity: atom(),
            outcome: atom(),
            cost_usd: float(),
            attempt_limit: pos_integer(),
            threshold: atom(),
            model: binary(),
            attempt_id: tuple() | nil
          }
  end

  defmodule CostEntry do
    @moduledoc false
    defstruct [:id, :run_key, :amount_usd, :kind, :recorded_at]

    @type t :: %__MODULE__{
            id: {binary(), binary(), binary(), atom(), pos_integer()},
            run_key: {binary(), binary()},
            amount_usd: float(),
            kind: :actual | :estimate,
            recorded_at: DateTime.t()
          }
  end

  defmodule Transcript do
    @moduledoc false
    defstruct [:attempt_id, :body, :bytes, :written_at]

    @type t :: %__MODULE__{
            attempt_id: {binary(), binary(), binary(), atom(), pos_integer()},
            body: binary(),
            bytes: pos_integer(),
            written_at: DateTime.t()
          }
  end

  @table_modules %{
    speckit_meta: Meta,
    speckit_seq: Seq,
    speckit_run: Run,
    speckit_run_settings: RunSettings,
    speckit_settings_amendment: SettingsAmendment,
    speckit_feature_run: FeatureRun,
    speckit_phase_attempt: PhaseAttempt,
    speckit_checkpoint: Checkpoint,
    speckit_escalation: Escalation,
    speckit_remediation_attempt: RemediationAttempt,
    speckit_cost_entry: CostEntry,
    speckit_transcript: Transcript
  }

  @type damaged :: {:error, {:damaged, term(), term()}}

  @doc "The table a given record struct belongs to."
  @spec table_for(struct()) :: atom()
  def table_for(%mod{}), do: table_for_module!(mod)

  @doc """
  Struct -> `:mnesia` record tuple (`{table, attr1_value, attr2_value, ...}`),
  attribute order from `Store.Schema.table/1`.
  """
  @spec encode(struct()) :: tuple()
  def encode(%mod{} = record) do
    table = table_for_module!(mod)
    attributes = Schema.table(table).attributes
    fields = Map.from_struct(record)
    values = Enum.map(attributes, &Map.fetch!(fields, &1))
    List.to_tuple([table | values])
  end

  @doc """
  `:mnesia` record tuple -> struct for `table`. Returns
  `{:error, {:damaged, key, reason}}` on any shape mismatch (wrong record
  name, wrong arity) — never defaults or coerces a field (FR-008, SC-011).
  Absence is the caller's concern (`{:error, :absent}`), not this function's.

  One mismatch is **not** damage: when `Schema`'s attribute list for a table no
  longer matches the shape that table was booted with, every row in it fails to
  decode and none of them is corrupt — the tables were never migrated to the
  shape this build expects. That happens whenever `Schema` changes under a
  running node, which in dev takes no deliberate act: recompiling is enough for
  the code reloader to swap the module in. Reporting it as
  `{:damaged, key, :shape_mismatch}` sent operators hunting a corrupt record
  and, worse, let a live run fail features over a store that was fine;
  `{:unmigrated_schema, table, expected, booted}` says what is actually wrong
  and implies the fix (restart, so migrations run).

  The snapshot lookup happens only on the failure path, so decoding a healthy
  row costs exactly what it did before. `Store.Shape` owns the snapshot because
  this module may not touch `:mnesia` to ask a table its shape (Principle I).
  """
  @spec decode(atom(), tuple()) :: {:ok, struct()} | damaged()
  def decode(table, tuple) when is_atom(table) and is_tuple(tuple) do
    with %{} = spec <- Schema.table(table) || :no_spec,
         mod when not is_nil(mod) <- Map.get(@table_modules, table),
         [^table | values] <- Tuple.to_list(tuple),
         true <- length(values) == length(spec.attributes) do
      {:ok, struct!(mod, Enum.zip(spec.attributes, values))}
    else
      _ -> {:error, {:damaged, safe_key(tuple), mismatch_reason(table)}}
    end
  rescue
    error -> {:error, {:damaged, safe_key(tuple), error}}
  end

  # Distinguishes "this row is the wrong shape" from "this whole table is".
  # `:shape_mismatch` whenever there is no recorded shape to compare against —
  # an unknown table, or a unit test that never booted a store — since without
  # a snapshot there is no evidence of an unmigrated table, only of a bad tuple.
  defp mismatch_reason(table) do
    expected = Schema.table(table) && Schema.table(table).attributes

    case Shape.mismatch(table, expected) do
      nil -> :shape_mismatch
      {^expected, booted} -> {:unmigrated_schema, table, expected, booted}
    end
  end

  defp table_for_module!(mod) do
    case Enum.find(@table_modules, fn {_table, m} -> m == mod end) do
      {table, ^mod} -> table
      nil -> raise ArgumentError, "no store table registered for #{inspect(mod)}"
    end
  end

  defp safe_key(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 2, do: elem(tuple, 1)
  defp safe_key(_), do: :unknown
end
