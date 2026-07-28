defmodule SpeckitOrchestrator.Store.Boot do
  @moduledoc """
  Boot sequence (018, research R4, contracts/schema.md § Location, node, and
  boot): mkdir -> set `:mnesia` dir -> create schema if absent -> start ->
  verify the node against the schema table -> create/verify tables ->
  wait_for_tables -> verify (and, on a fresh schema, record) node ownership
  against `speckit_meta`, applying pending migrations -> write-probe. Runs
  before any child spec in `Application.start/2` (FR-009): a failure returns
  `{:error, reason}` so the OTP application never finishes booting with a
  half-ready store.

  Node ownership is checked against **both** sources research R2 names: the
  built-in schema table (`Store.Mnesia.schema_nodes/0`) catches a schema
  created by a different node before any table read is attempted;
  `speckit_meta`'s own `:node` row is the second, Mnesia-internals-independent
  check, and is also where a fresh schema's ownership is first recorded.
  """

  alias SpeckitOrchestrator.Config
  alias SpeckitOrchestrator.Store.{Migrations, Mnesia, Schema}

  @meta :speckit_meta

  @doc "Run the full boot sequence against `dir` (defaults to `Config.store_dir/0`)."
  @spec start!(String.t()) :: :ok | {:error, term()}
  def start!(dir \\ Config.store_dir()) do
    # `:mnesia` sits in `extra_applications`, so OTP already auto-started it
    # (default, dir-less, RAM-only schema) as a dependency before this
    # function ever runs. Stop it first so `set_dir/1` + `create_schema/1`
    # below are what actually determines where and how the schema lives.
    Mnesia.stop()

    with :ok <- File.mkdir_p(dir),
         :ok <- Mnesia.set_dir(dir),
         :ok <- Mnesia.create_schema([node()]),
         :ok <- Mnesia.start(),
         :ok <- verify_schema_ownership(),
         :ok <- Mnesia.create_tables(),
         :ok <- Mnesia.wait_for_tables(Schema.names(), 30_000),
         :ok <- verify_and_migrate(),
         :ok <- write_probe() do
      :ok
    end
  end

  defp verify_schema_ownership do
    expected = node()
    schema_nodes = Mnesia.schema_nodes()

    if expected in schema_nodes do
      :ok
    else
      {:error, {:schema_node_mismatch, expected, schema_nodes}}
    end
  end

  defp verify_and_migrate do
    expected = node()

    Mnesia.transaction(fn ->
      case Mnesia.read(@meta, :node) do
        [] ->
          record_fresh_schema(expected)
          :fresh

        [{@meta, :node, ^expected}] ->
          case Mnesia.read(@meta, :schema_version) do
            [{@meta, :schema_version, version}] -> {:existing, version}
            [] -> {:existing, nil}
          end

        [{@meta, :node, found}] ->
          {:mismatch, found}
      end
    end)
    |> case do
      {:ok, :fresh} -> :ok
      {:ok, {:mismatch, found}} -> {:error, {:schema_node_mismatch, expected, found}}
      {:ok, {:existing, version}} -> reconcile_version(version)
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_fresh_schema(node) do
    Mnesia.write({@meta, :node, node})
    Mnesia.write({@meta, :schema_version, Migrations.current_version()})
    Mnesia.write({@meta, :created_at, DateTime.utc_now()})
  end

  defp reconcile_version(version) do
    current = Migrations.current_version()

    cond do
      version == current ->
        :ok

      is_integer(version) and version < current ->
        with :ok <- Migrations.apply_pending(version),
             {:ok, :ok} <-
               Mnesia.transaction(fn -> Mnesia.write({@meta, :schema_version, current}) end) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, {:schema_version_ahead, version, current}}
    end
  end

  defp write_probe do
    case Mnesia.transaction(fn -> Mnesia.write({@meta, :write_probe, DateTime.utc_now()}) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
