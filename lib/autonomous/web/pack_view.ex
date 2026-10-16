defmodule Autonomous.Web.PackView do
  @moduledoc """
  Pure view state for the Configuration page's "target pack" row (feature 044,
  data-model "Console view state"). Maps `TargetPack.source/1` onto what the
  row shows; a refusal is rendered through `Report.format_reason/1`. Never
  calls `inspect/1`.
  """

  alias Autonomous.Report

  @type state :: {:supplied, pos_integer()} | {:committed, pos_integer()} | {:refused, String.t()}

  @doc "`result` is `TargetPack.source/1`'s return."
  @spec state(
          {:ok, %{source: :supplied | :committed, contract: pos_integer()}}
          | {:error, term()}
        ) ::
          state()
  def state({:ok, %{source: :supplied, contract: n}}), do: {:supplied, n}
  def state({:ok, %{source: :committed, contract: n}}), do: {:committed, n}
  def state({:error, reason}), do: {:refused, Report.format_reason(reason)}

  @doc "The row's value text for a non-refused state."
  @spec summary(state()) :: String.t()
  def summary({:supplied, n}), do: "supplied by the orchestrator — contract #{n}"
  def summary({:committed, n}), do: "committed in the target — contract #{n}"
  def summary({:refused, text}), do: text

  @doc "The `data-pack-source` name (never a value)."
  @spec source_name(state()) :: String.t()
  def source_name({:supplied, _}), do: "supplied"
  def source_name({:committed, _}), do: "committed"
  def source_name({:refused, _}), do: "refused"
end
