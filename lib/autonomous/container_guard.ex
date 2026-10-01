defmodule Autonomous.ContainerGuard do
  @moduledoc """
  Refuses to boot the orchestrator outside its container image (feature 031,
  FR-004/FR-005).

  `decide/2` is pure; `check!/0` and `containerized?/0` are the thin IO
  wrappers over `System.get_env/1` and the `:require_container` app env. The
  image sets `AUTONOMOUS_CONTAINER=1`; only the `:test` config sets
  `require_container: false`. The check prevents accidental host starts — it is
  not a security boundary. See `specs/031-containerized-runtime/contracts/boot-guard.md`.
  """

  @marker_env "AUTONOMOUS_CONTAINER"

  @doc """
  Pure decision: `:ok` when the container is not required, or the marker is
  `"1"`; `{:error, :not_in_container}` otherwise.
  """
  @spec decide(marker :: String.t() | nil, required? :: boolean()) ::
          :ok | {:error, :not_in_container}
  def decide(_marker, false), do: :ok
  def decide("1", true), do: :ok
  def decide(_marker, true), do: {:error, :not_in_container}

  @doc "Raises `RuntimeError` with the operator-facing refusal when `decide/2` refuses."
  @spec check!() :: :ok
  def check! do
    case decide(marker(), required?()) do
      :ok -> :ok
      {:error, :not_in_container} -> raise refusal_message()
    end
  end

  @doc """
  `true` only when the container is required **and** the marker is set. The
  marker alone is not enough: `mix test` inside the image must behave like the
  host suite, and the `:test` config sets `require_container: false`.
  """
  @spec containerized?() :: boolean()
  def containerized?, do: required?() and marker() == "1"

  @doc "The exact refusal text (a test assertion)."
  @spec refusal_message() :: String.t()
  def refusal_message do
    """
    autonomous refuses to start outside its container (AUTONOMOUS_CONTAINER is not set).
    Run it with one of:
      scripts/autonomous shell   --target <repo>
      scripts/autonomous console --target <repo>
      scripts/autonomous release --target <repo>
    `mix compile` and `mix test` still work on the host. This check prevents accidental
    host starts; it is not a security boundary.
    """
    |> String.trim_trailing()
  end

  defp marker, do: System.get_env(@marker_env)
  defp required?, do: Application.get_env(:autonomous, :require_container, true)
end
