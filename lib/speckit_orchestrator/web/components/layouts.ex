defmodule SpeckitOrchestrator.Web.Layouts do
  @moduledoc """
  Root/app chrome shared by every console view (global chrome in
  `contracts/routes.md`): fixed left nav (FR-001) with an Escalations count
  badge (FR-002), a context strip (FR-003), a persistent status bar (FR-004),
  and a toast slot (FR-005).

  Nav/context/run data is computed fresh on every render from the
  authoritative sources (`Coordinator`, `Ledger`, `Config`) rather than
  threaded through every LiveView's assigns — cheap in-memory reads, and it
  means the shared chrome always reflects the live run (FR-033) without each
  view re-deriving it.
  """

  use SpeckitOrchestrator.Web, :html

  alias SpeckitOrchestrator.{Config, Coordinator, Ledger}

  embed_templates("layouts/*")

  @nav_items [
    {"/", "Mission Control"},
    {"/dag", "Pipeline DAG"},
    {"/trigger", "Trigger Run"},
    {"/escalations", "Escalations"},
    {"/transcripts", "Transcripts"},
    {"/config", "Configuration"}
  ]

  @doc "The six fixed left-nav items as `{path, label}` (FR-001)."
  @spec nav_items() :: [{String.t(), String.t()}]
  def nav_items, do: @nav_items

  @doc "Count of features in an escalated/halted/failed state (FR-002)."
  @spec escalations_count() :: non_neg_integer()
  def escalations_count do
    case coordinator_status() do
      nil ->
        0

      status ->
        status.per_feature
        |> Map.values()
        |> Enum.count(&(&1.status in [:escalated, :halted, :failed]))
    end
  end

  @doc "Context-strip data: target repo, CLI auth health, runtime health (FR-003)."
  @spec context() :: %{repo: String.t(), cli_auth: String.t(), runtime: String.t()}
  def context do
    %{
      repo: Config.repo(),
      cli_auth: if(System.find_executable("claude"), do: "available", else: "not found"),
      runtime: if(Process.whereis(Ledger), do: "up", else: "down")
    }
  end

  @doc "Status-bar / no-active-run view data (FR-004, FR-036)."
  @spec run_view() :: map()
  def run_view do
    status = coordinator_status()
    ledger = Ledger.snapshot()

    %{
      active?: status != nil,
      title: if(status, do: "Active run", else: "No active run"),
      mode: if(Config.pr_workflow?(), do: :stacked_pr, else: :parallel_waves),
      committed: ledger.committed * 1.0,
      reserved: ledger.reserved * 1.0,
      budget: ledger.budget * 1.0,
      tripped?: ledger.tripped?,
      clock: DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()
    }
  end

  defp coordinator_status do
    if Process.whereis(Coordinator) do
      Coordinator.status(Coordinator)
    end
  end
end
