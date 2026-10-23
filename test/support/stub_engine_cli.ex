defmodule Autonomous.StubEngineCli do
  @moduledoc """
  Builds a throwaway module implementing `Autonomous.ContainerEngine.Cli` for one
  test (feature 046). The probe and the cleanup run the CLI inside a supervised
  task, so state cannot live in the test process: each stub module keeps its
  handler and its recorded calls in `:persistent_term` / an `Agent` found by the
  module name.

      cli = StubEngineCli.new(fn ["ps", "-aq"] -> {:ok, ""}; _ -> {:ok, ""} end)
      ContainerEngine.cleanup(cli: cli, advertised?: true)
      StubEngineCli.calls(cli)   #=> [["ps", "-aq"], ...]
  """

  @doc "Create a stub whose `run/2` returns `handler.(args)`; returns the module."
  @spec new((list() -> term())) :: module()
  def new(handler) when is_function(handler, 1) do
    mod = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")
    {:ok, agent} = Agent.start(fn -> [] end)
    :persistent_term.put({__MODULE__, mod}, {handler, agent})

    Module.create(
      mod,
      quote do
        @behaviour Autonomous.ContainerEngine.Cli
        @impl true
        def run(args, timeout), do: Autonomous.StubEngineCli.invoke(__MODULE__, args, timeout)
      end,
      Macro.Env.location(__ENV__)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Agent.stop(agent)
      :persistent_term.erase({__MODULE__, mod})
    end)

    mod
  end

  @doc false
  def invoke(mod, args, _timeout) do
    {handler, agent} = :persistent_term.get({__MODULE__, mod})
    Agent.update(agent, &[args | &1])
    handler.(args)
  end

  @doc "Calls the stub received, oldest first."
  @spec calls(module()) :: [[String.t()]]
  def calls(mod) do
    {_handler, agent} = :persistent_term.get({__MODULE__, mod})
    agent |> Agent.get(& &1) |> Enum.reverse()
  end
end
