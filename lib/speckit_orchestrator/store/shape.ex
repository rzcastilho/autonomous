defmodule SpeckitOrchestrator.Store.Shape do
  @moduledoc """
  The attribute list each table actually had **at boot**, so a later `Schema`
  change can be told apart from a damaged row.

  `Store.Boot` records this once, after migrations have run and it has verified
  the tables agree with `Schema` (`Boot.verify_table_shapes/0`). From then on the
  snapshot is what the tables on disk look like. If `Schema` later disagrees with
  it, the tables did not change — the *code* did, without a reboot to migrate
  them. That is not a hypothetical: in dev, recompiling is enough for the code
  reloader to swap `Schema` into a running node, and every read of the changed
  table then fails against rows that are perfectly intact.

  Kept out of `Records` on purpose. `Records` is a pure encode/decode surface
  and may not reference `:mnesia` (Constitution Principle I, enforced by
  `store_boundary_test.exs`), so it cannot ask a live table its shape. It can
  read a snapshot someone else captured — which is also the sharper question,
  since "`Schema` changed since boot" is the actual condition.

  A `:persistent_term`, not a process: read on `Records.decode/2`'s failure path,
  never written after boot, and it must survive anything that could restart a
  supervised process without re-running boot.
  """

  @key {__MODULE__, :booted_attributes}

  @doc "Record the shapes the tables were booted with, as `%{table => attributes}`."
  @spec record(%{atom() => [atom()]}) :: :ok
  def record(shapes) when is_map(shapes), do: :persistent_term.put(@key, shapes)

  @doc "Forget the recorded shapes (test support; a fresh boot re-records them)."
  @spec forget() :: :ok
  def forget do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc "The attributes `table` was booted with, or `nil` if boot never recorded any."
  @spec booted(atom()) :: [atom()] | nil
  def booted(table), do: Map.get(:persistent_term.get(@key, %{}), table)

  @doc """
  `{expected, booted}` when `expected` — `Schema`'s current attribute list for
  `table` — no longer matches what the table was booted with, else `nil`.

  `nil` when boot never recorded a shape for the table: with no snapshot there is
  no evidence of an unmigrated table, only of a tuple that does not fit.
  """
  @spec mismatch(atom(), [atom()] | nil) :: {[atom()], [atom()]} | nil
  def mismatch(table, expected)

  def mismatch(_table, nil), do: nil

  def mismatch(table, expected) do
    case booted(table) do
      nil -> nil
      ^expected -> nil
      booted -> {expected, booted}
    end
  end
end
