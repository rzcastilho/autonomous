defmodule SpeckitOrchestrator.StoreCase do
  @moduledoc """
  Shared `ExUnit.CaseTemplate` for tests that touch the store (018, research
  R14). The Mnesia directory is node-global, so there is one store for the
  whole suite — booted automatically when the `:speckit_orchestrator`
  application starts, against the tmp `autonomous_root` test config
  (`config/config.exs`), never `~/.autonomous`. This case template clears
  every table and the persistence breaker before each test, keeping tests
  independent without a schema per test. `async: false` — table clearing is a
  suite-wide side effect.
  """

  use ExUnit.CaseTemplate

  alias SpeckitOrchestrator.Store.{Health, Mnesia, Schema}

  using do
    quote do
      alias SpeckitOrchestrator.Store

      alias SpeckitOrchestrator.Store.{
        Boot,
        Capacity,
        Export,
        Health,
        Ids,
        Mnesia,
        Prune,
        Query,
        Records,
        Schema,
        Writer
      }
    end
  end

  setup do
    stop_lingering_run()
    Enum.each(Schema.names(), &Mnesia.clear_table/1)
    Health.clear()
    reset_console_projection()
    :ok
  end

  # `ConsoleProjection` is node-global and never persists, so every phase
  # telemetry event any earlier test emitted is still folded into it. With no
  # live Coordinator, `ConsoleReadModel.overlay_observed/2` turns a leftover
  # `:active` phase cell into a `:running` row — Mission Control then draws the
  # recovered-run banner instead of "no active run", and the Pipeline Chain
  # grows a phantom ad-hoc lane instead of the empty backlog. Which test ran
  # first decided the outcome. `:sys.replace_state/2` is processed in mailbox
  # order, so telemetry already queued from an earlier test is folded (and
  # discarded) before the reset lands.
  defp reset_console_projection do
    case Process.whereis(SpeckitOrchestrator.ConsoleProjection) do
      nil ->
        :ok

      pid ->
        :sys.replace_state(pid, &%{&1 | model: SpeckitOrchestrator.ConsoleReadModel.new()})
        :ok
    end
  end

  # A run's Coordinator and StackTracker live under `CoordinatorSup`, not linked
  # to whoever started them — a run has to outlive the console request that asked
  # for it. That means a test's Coordinator is no longer killed the instant its
  # test process exits: it can still be draining while the next test runs, and a
  # drain that ends on a non-`:done` feature *parks the run in the store*. The
  # next test then gets `{:error, {:parked_run, …}}` from a repository it never
  # touched. Retire them before clearing, so no leftover process writes into the
  # table set this setup just emptied.
  defp stop_lingering_run do
    Enum.each([SpeckitOrchestrator.Coordinator, SpeckitOrchestrator.StackTracker], fn name ->
      case Process.whereis(name) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    end)
  end
end
