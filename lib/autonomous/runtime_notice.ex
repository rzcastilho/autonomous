defmodule Autonomous.RuntimeNotice do
  @moduledoc """
  The non-container start warning (feature 039, contracts/run-start.md § 4).

  With the strict profile gone, every orchestrator session runs with the full
  tool set and no in-tree deny list; the container is the boundary. A run that
  starts outside it is allowed — it only happens where `ContainerGuard` was
  deliberately disabled (host development, test) — but the operator is told,
  loudly, and the run proceeds.

  Pure: the caller reads `ContainerGuard.containerized?/0` at the edge and
  passes the answer in.
  """

  @doc """
  `nil` inside the container; otherwise the multi-line warning text to log
  (never an error — the run proceeds).
  """
  @spec container_warning(boolean()) :: String.t() | nil
  def container_warning(true), do: nil

  def container_warning(false) do
    """
    This run is starting OUTSIDE the container.
    Sessions run with full tool access and no in-tree deny list — the container
    is the only boundary, and it is not present here.
    The supported runtime is scripts/autonomous (see docs/container.md).
    The run proceeds.\
    """
  end
end
