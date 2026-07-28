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
    Enum.each(Schema.names(), &Mnesia.clear_table/1)
    Health.clear()
    :ok
  end
end
