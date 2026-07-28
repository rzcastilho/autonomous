defmodule SpeckitOrchestrator.Store.Mnesia do
  @moduledoc """
  The ONLY module that calls `:mnesia` (018, contracts/schema.md;
  Principle I). `Store.Boot`/`Store.Migrations` use the boot-time functions;
  `Store.Writer`/`Store.Query` use `transaction/1` plus the read/write
  primitives below — neither touches `:mnesia` directly.
  """

  alias SpeckitOrchestrator.Store.Schema

  @doc "Point `:mnesia`'s `:dir` env at `path` before `start/0`. Must run before `create_schema/1`/`start/0`."
  @spec set_dir(String.t()) :: :ok
  def set_dir(path) when is_binary(path) do
    Application.put_env(:mnesia, :dir, String.to_charlist(path))
    :ok
  end

  @doc "Create the on-disk schema for `nodes` if none exists yet; `{:already_exists, _}` is treated as success."
  @spec create_schema([node()]) :: :ok | {:error, term()}
  def create_schema(nodes) do
    case :mnesia.create_schema(nodes) do
      :ok -> :ok
      {:error, {_node, {:already_exists, _}}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Start the local `:mnesia` node."
  @spec start() :: :ok
  def start, do: :ok = :mnesia.start()

  @doc """
  Stop the local `:mnesia` node. Safe to call even when not running (returns
  `:stopped` either way) — `Store.Boot` calls this unconditionally first,
  because `:mnesia` being listed in `extra_applications` means OTP already
  auto-started it (default, dir-less, RAM-only schema) as a dependency before
  `Application.start/2` runs; stopping it first hands full control of
  dir/schema/start back to the boot sequence.
  """
  @spec stop() :: :stopped
  def stop, do: :mnesia.stop()

  @doc "Nodes the on-disk schema table belongs to (research R2's first ownership check)."
  @spec schema_nodes() :: [node()]
  def schema_nodes, do: :mnesia.table_info(:schema, :disc_copies)

  @doc "Create every table `Store.Schema` declares that does not already exist."
  @spec create_tables() :: :ok | {:error, term()}
  def create_tables do
    Enum.reduce_while(Schema.tables(), :ok, fn spec, :ok ->
      case create_table(spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_table(%{name: name} = spec) do
    opts =
      [attributes: spec.attributes, type: spec.type, index: spec.index] ++
        [{spec.storage, [node()]}]

    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Block until every table in `tables` is loaded, or `{:error, {:timeout, tables}}`."
  @spec wait_for_tables([atom()], timeout()) :: :ok | {:error, term()}
  def wait_for_tables(tables, timeout \\ 30_000) do
    case :mnesia.wait_for_tables(tables, timeout) do
      :ok -> :ok
      {:timeout, bad_tables} -> {:error, {:timeout, bad_tables}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Run `fun` (arity 0) inside a `:mnesia` transaction; `{:ok, result}` /
  `{:error, reason}`, normalizing `:mnesia.transaction/1`'s
  `{:atomic, _} | {:aborted, _}`.
  """
  @spec transaction((-> result)) :: {:ok, result} | {:error, term()} when result: var
  def transaction(fun) when is_function(fun, 0) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> {:ok, result}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Abort the enclosing transaction with `reason`. Call only from inside `transaction/1`."
  @spec abort(term()) :: no_return()
  def abort(reason), do: :mnesia.abort(reason)

  @doc "Transactional write of a raw record tuple. Call only from inside `transaction/1`."
  @spec write(tuple()) :: :ok
  def write(record) when is_tuple(record), do: :mnesia.write(record)

  @doc "Transactional delete by key. Call only from inside `transaction/1`."
  @spec delete(atom(), term()) :: :ok
  def delete(table, key), do: :mnesia.delete({table, key})

  @doc "Transactional read by key with `lock`. Call only from inside `transaction/1`."
  @spec read(atom(), term(), :read | :write) :: [tuple()]
  def read(table, key, lock \\ :read), do: :mnesia.read(table, key, lock)

  @doc "Transactional secondary-index read. Call only from inside `transaction/1`."
  @spec index_read(atom(), term(), atom()) :: [tuple()]
  def index_read(table, value, index_attr), do: :mnesia.index_read(table, value, index_attr)

  @doc """
  Non-authoritative dirty read — console liveness display only, never a write
  path, never a resume/gate/cost/export/prune source (contracts/schema.md §
  Read discipline).
  """
  @spec dirty_read(atom(), term()) :: [tuple()]
  def dirty_read(table, key), do: :mnesia.dirty_read(table, key)

  @doc "Table metadata (`:memory`, `:size`, `:disc_copies`, ...). No transaction required."
  @spec table_info(atom(), atom()) :: term()
  def table_info(table, item), do: :mnesia.table_info(table, item)

  @doc "`:mnesia.transform_table/3` for a `Store.Migrations` attribute change."
  @spec transform_table(atom(), (tuple() -> tuple()), [atom()]) :: :ok | {:error, term()}
  def transform_table(table, fun, new_attributes) do
    case :mnesia.transform_table(table, fun, new_attributes) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Delete every row from `table`. Test support only (`StoreCase`) — never called from a run's write path."
  @spec clear_table(atom()) :: :ok
  def clear_table(table) do
    case :mnesia.clear_table(table) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> raise "failed to clear #{inspect(table)}: #{inspect(reason)}"
    end
  end
end
