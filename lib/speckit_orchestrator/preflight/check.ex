defmodule SpeckitOrchestrator.Preflight.Check do
  @moduledoc """
  One verified environment fact (FR-032, `data-model.md` §2).

  `new/1` enforces the invariant `status != :ok ⇒ fix` present and non-empty
  (SC-007) — a check that fails or warns with no `fix` is a programmer error
  in the collector, not a state to persist and hand to an operator.
  """

  @enforce_keys [:id, :category, :status, :detail]
  defstruct [:id, :category, :status, :detail, :expected, :observed, :fix]

  @type category :: :tool | :credential | :mount | :target_repo | :path_identity | :runtime
  @type status :: :ok | :warn | :fail

  @type t :: %__MODULE__{
          id: atom(),
          category: category(),
          status: status(),
          detail: String.t(),
          expected: String.t() | nil,
          observed: String.t() | nil,
          fix: String.t() | nil
        }

  @doc """
  Build a `t()`, raising `ArgumentError` if `status != :ok` and `fix` is
  missing or empty.
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    check = struct!(__MODULE__, attrs)

    if check.status != :ok and (is_nil(check.fix) or check.fix == "") do
      raise ArgumentError,
            "Preflight.Check #{inspect(check.id)} has status #{inspect(check.status)} " <>
              "but no fix"
    end

    check
  end
end
