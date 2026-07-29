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
  """

  alias SpeckitOrchestrator.Store.Mnesia

  @type migration :: {pos_integer(), String.t(), (-> :ok | {:error, term()})}

  @doc "The schema version this build of the orchestrator understands."
  @spec current_version() :: pos_integer()
  def current_version, do: 2

  @doc "Every migration, ascending by version."
  @spec all() :: [migration()]
  def all do
    [
      {2, "019 clean break — pre-019 records are not readable",
       fn -> {:error, {:incompatible_record, 1}} end}
    ]
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
