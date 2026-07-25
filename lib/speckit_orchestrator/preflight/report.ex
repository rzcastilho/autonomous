defmodule SpeckitOrchestrator.Preflight.Report do
  @moduledoc """
  The aggregate persisted before any feature spend (FR-034, `data-model.md`
  §3, `contracts/preflight-report.md` §1-§2).

  `build/1` is pure — no IO — so every derivation is unit-tested without a
  container: `status` is derived from `checks`, and `checks` is sorted by
  category then id so the same collected facts always yield a
  byte-identical ordering.
  """

  alias SpeckitOrchestrator.ImageInfo
  alias SpeckitOrchestrator.Preflight.Check

  @enforce_keys [:status, :checks, :run_state_root, :repo, :collected_at]
  defstruct [
    :status,
    :checks,
    :image,
    :resolved_versions,
    :run_state_root,
    :repo,
    :collected_at
  ]

  @type t :: %__MODULE__{
          status: :pass | :warn | :fail,
          checks: [Check.t()],
          image: ImageInfo.t() | nil,
          resolved_versions: %{String.t() => String.t()},
          run_state_root: String.t(),
          repo: String.t(),
          collected_at: DateTime.t()
        }

  @doc """
  Build a report from collected facts: `%{checks:, run_state_root:, repo:,
  collected_at:}` required; `:image` and `:resolved_versions` optional.
  """
  @spec build(map()) :: t()
  def build(%{checks: checks} = fields) do
    %__MODULE__{
      status: derive_status(checks),
      checks: sort_checks(checks),
      image: Map.get(fields, :image),
      resolved_versions: Map.get(fields, :resolved_versions, %{}),
      run_state_root: Map.fetch!(fields, :run_state_root),
      repo: Map.fetch!(fields, :repo),
      collected_at: Map.fetch!(fields, :collected_at)
    }
  end

  defp derive_status(checks) do
    cond do
      Enum.any?(checks, &(&1.status == :fail)) -> :fail
      Enum.any?(checks, &(&1.status == :warn)) -> :warn
      true -> :pass
    end
  end

  defp sort_checks(checks) do
    Enum.sort_by(checks, fn c -> {to_string(c.category), to_string(c.id)} end)
  end

  @doc "The JSON-safe map matching `contracts/preflight-report.md` §1."
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = report) do
    %{
      "status" => to_string(report.status),
      "collected_at" => DateTime.to_iso8601(report.collected_at),
      "repo" => report.repo,
      "run_state_root" => report.run_state_root,
      "image" => image_json(report.image),
      "resolved_versions" => report.resolved_versions,
      "checks" => Enum.map(report.checks, &check_json/1)
    }
  end

  @doc "Pretty-printed JSON, matching the repo's process-generated-JSON convention."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = report) do
    report |> to_json_map() |> Jason.encode!(pretty: true)
  end

  defp image_json(nil), do: nil

  defp image_json(%ImageInfo{} = image) do
    %{
      "source_revision" => image.source_revision,
      "orchestrator_version" => image.orchestrator_version,
      "image_ref" => image.image_ref,
      "built_at" => DateTime.to_iso8601(image.built_at),
      "elixir" => image.elixir,
      "otp" => image.otp,
      "base_digests" => image.base_digests,
      "tools" => image.tools
    }
  end

  defp check_json(%Check{} = check) do
    %{
      "id" => to_string(check.id),
      "category" => to_string(check.category),
      "status" => to_string(check.status),
      "detail" => check.detail,
      "expected" => check.expected,
      "observed" => check.observed,
      "fix" => check.fix
    }
  end
end
