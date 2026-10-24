defmodule Autonomous.Web.ContainerEngineView do
  @moduledoc """
  Pure view state for the Configuration page's "container engine" row (feature 046,
  data-model.md / contracts/configuration-surface.md). `:hidden` renders nothing, so
  an instance started without `--docker` keeps a byte-identical page. The row never
  shows `available` without a probe from the current render cycle. Never calls
  `inspect/1`.
  """

  @type state ::
          :hidden
          | :checking
          | {:available, version :: String.t()}
          | {:unreachable, cause :: String.t()}

  @doc "`requested?` is `ContainerEngine.requested?/0`: the instance was started with `--docker`."
  @spec state(boolean()) :: :hidden | :checking
  def state(false), do: :hidden
  def state(true), do: :checking

  @doc "Maps a `ContainerEngine.probe/1` result onto the row state."
  @spec from_probe({:ok, String.t()} | {:error, String.t()}) :: state()
  def from_probe({:ok, version}), do: {:available, version}
  def from_probe({:error, cause}), do: {:unreachable, cause}

  @doc "The state shown when the probe task itself exits."
  @spec crashed() :: state()
  def crashed, do: {:unreachable, "the engine probe crashed — reload to retry"}

  @doc "The row's value text (`\"\"` for `:hidden`, which is never rendered)."
  @spec summary(state()) :: String.t()
  def summary(:hidden), do: ""
  def summary(:checking), do: "checking…"
  def summary({:available, version}), do: "available — engine " <> version
  def summary({:unreachable, cause}), do: "unreachable — " <> cause
end
